# Conductor Mode — Multi-Device Test Orchestration

## Overview

Conductor Mode allows a single iPad to orchestrate diagnostic tests between multiple other iPads. Instead of manually connecting pairs and running tests, the conductor discovers all nearby devices, selects pairs, instructs them to test each other, and collects all reports centrally.

**Example:** Device 1 (Conductor) tells Device 2 and Device 3 to test each other. Devices 2 and 3 connect peer-to-peer, run the full test suite, and send the report back to Device 1. The conductor can then queue the next pair (e.g. Device 2 and Device 4) without any manual intervention on those devices.

---

## Device Roles

| Role | Description | Connections | Can Run Tests |
|---|---|---|---|
| **Conductor** | Orchestrates tests, collects reports | N connections (one per managed device) | Yes (can also test directly with any device) |
| **Agent** | Waits for instructions from conductor | 1 to conductor + 1 to test partner | Only when instructed |
| **Standalone** | Current behavior (Controller/Responder) | 1 connection | Yes (Controller only) |

A device starts as **Standalone** by default (current behavior). The user can switch to **Conductor** mode from the sidebar. When a conductor connects to a device, that device automatically becomes an **Agent**.

---

## Architecture Changes

### 1. Multi-Connection Support

**Current:** `BonjourService` holds a single `ConnectionManager` and `DiagnosticEngine`.

**New:** `BonjourService` (or a new `ConductorService`) manages a dictionary of connections keyed by device ID.

```
Current:
  BonjourService
    ├── connectionManager: ConnectionManager?
    ├── diagnosticEngine: DiagnosticEngine?
    └── connectedPeer: PeerDevice?

New:
  BonjourService
    ├── mode: AppMode (.standalone, .conductor, .agent)
    ├── connections: [UUID: DeviceConnection]  // conductor holds many
    ├── conductorConnection: DeviceConnection? // agent holds one to conductor
    ├── testPartnerConnection: DeviceConnection? // agent holds one during test
    └── discoveredPeers: [PeerDevice]

  DeviceConnection (new struct/class)
    ├── peer: PeerDevice
    ├── connectionManager: ConnectionManager
    ├── diagnosticEngine: DiagnosticEngine?
    └── state: ConnectionState
```

### 2. New Message Types

Add to `DiagnosticMessage`:

```swift
// Conductor -> Agent: assign role
case roleAssignment(role: String) // "agent"

// Conductor -> Agent: connect to another device and run tests
case orchestrateTest(
    targetDeviceName: String,     // Bonjour service name to connect to
    targetDeviceID: UUID,         // unique ID of the target
    suiteConfig: TestSuiteConfig  // which tests to run, parameters
)

// Agent -> Conductor: test orchestration status updates
case orchestrationStatus(
    phase: String,                // "connecting", "running", "completed", "failed"
    detail: String                // human-readable status
)

// Agent -> Conductor: completed report
case orchestrationReport(reportJSON: Data)

// Conductor -> Agent: cancel current test
case orchestrationCancel
```

### 3. Test Suite Configuration

Currently `TestSuiteRunner.runFullSuite()` is hardcoded. Extract a `TestSuiteConfig` that the conductor can customize per-pair:

```swift
struct TestSuiteConfig: Codable {
    var latencyBurstCount: Int = 100
    var latencyBurstIntervalMs: Int = 50
    var throughputBytes: Int = 10_000_000
    var jitterSampleCount: Int = 150
    var jitterIntervalMs: Int = 80
    var packetLossCount: Int = 500
    var packetLossIntervalMs: Int = 10
    var runLatencyUnderLoad: Bool = true
    var runHeavyLoad: Bool = true
}
```

### 4. Connection Flow

#### Conductor Setup
1. User enables "Conductor Mode" from sidebar
2. `BonjourService.mode` changes to `.conductor`
3. App continues advertising and browsing
4. Discovered devices appear in a "Fleet" list
5. Tapping a device connects to it (multiple connections supported)
6. Connected device receives `roleAssignment(role: "agent")` and switches to agent mode

#### Test Orchestration Flow
1. Conductor selects two agents from the fleet (e.g. Device 2 and Device 3)
2. Conductor sends `orchestrateTest` to Device 2 with Device 3's Bonjour name
3. Device 2:
   a. Uses `NWBrowser` to find Device 3's Bonjour service
   b. Connects to Device 3 via `NWConnection`
   c. Device 3 receives the connection and accepts (it knows to expect it because the conductor also sent it an `orchestrateTest`)
   d. Device 2 runs the test suite as Controller
   e. Device 2 sends status updates to conductor via `orchestrationStatus`
   f. Device 2 sends completed report to conductor via `orchestrationReport`
   g. Device 2 disconnects from Device 3
4. Conductor receives the report, saves it to the database
5. Conductor can now queue the next pair

```
Conductor (Device 1)
    │
    ├── Connection to Device 2 (Agent)
    │       │
    │       └── orchestrateTest("Device 3") ──────┐
    │                                              │
    ├── Connection to Device 3 (Agent)             │
    │       │                                      │
    │       └── orchestrateTest("Device 2") ──────┐│
    │                                             ││
    │           Device 2 ◄════ test ════► Device 3
    │               │                        (peer-to-peer)
    │               │
    │       ◄── orchestrationReport(report)
    │
    └── Saves report locally
```

#### Sequence Diagram

```
Conductor          Device 2 (Agent)     Device 3 (Agent)
    │                    │                    │
    │──roleAssignment───►│                    │
    │──roleAssignment────────────────────────►│
    │                    │                    │
    │  [User selects pair: D2 + D3]          │
    │                    │                    │
    │──orchestrateTest──►│                    │
    │   (target: D3)     │                    │
    │──orchestrateTest────────────────────────►│
    │   (target: D2)     │                    │
    │                    │                    │
    │                    │◄══ Bonjour P2P ═══►│
    │                    │   NWConnection      │
    │                    │                    │
    │◄─status:connecting─│                    │
    │                    │                    │
    │                    │── test pings ──────►│
    │                    │◄── test pongs ──────│
    │                    │── throughput ──────►│
    │                    │   ... all phases    │
    │                    │                    │
    │◄─status:running────│                    │
    │  (phase updates)   │                    │
    │                    │                    │
    │◄─orchestrationReport│                   │
    │   (full JSON)      │                    │
    │                    │                    │
    │◄─status:completed──│                    │
    │                    │──disconnect────────►│
    │                    │                    │
    │  [Conductor saves report]              │
    │  [Queue next pair if any]              │
```

---

## UI Changes

### Sidebar

```
Devices
├── This Device
│   ├── iPad 1 (Conductor)     ← new mode indicator
│   ├── Advertising ●
│   └── Browsing ●
│
├── Fleet (3 devices)           ← new section (conductor mode only)
│   ├── ● iPad 2 — A16 — Connected
│   ├── ● iPad 3 — M3 — Connected
│   └── ● iPad 4 — M4 — Discovered
│
├── Reports
│   ├── Saved Reports
│   └── Analytics
│
└── Mode
    └── [Conductor Mode: ON]    ← toggle
```

### Conductor Dashboard (new detail view)

When in conductor mode and no test is running, show:

```
┌─────────────────────────────────────────────────┐
│ Fleet Status                                     │
│ 3 devices connected, 1 discovered               │
│                                                  │
│ ┌──────────┐  ┌──────────┐  ┌──────────┐       │
│ │ iPad 2   │  │ iPad 3   │  │ iPad 4   │       │
│ │ A16      │  │ M3       │  │ M4       │       │
│ │ ● Ready  │  │ ● Ready  │  │ ○ Disco  │       │
│ └──────────┘  └──────────┘  └──────────┘       │
│                                                  │
│ ─── Test Queue ──────────────────────────────── │
│                                                  │
│ Pair 1: iPad 2 ↔ iPad 3    [Remove]             │
│ Pair 2: iPad 2 ↔ iPad 4    [Remove]             │
│ Pair 3: iPad 3 ↔ iPad 4    [Remove]             │
│                                                  │
│ [Add Pair]    [Test All Pairs]   [Run Queue]    │
│                                                  │
│ ─── Recent Results ─────────────────────────── │
│                                                  │
│ A16 vs M3: Good (22ms avg)    [View Report]     │
│ A16 vs M4: Excellent (8ms)    [View Report]     │
│ M3 vs M4: Good (15ms avg)     [View Report]     │
│                                                  │
└─────────────────────────────────────────────────┘
```

**"Test All Pairs" button:** Automatically generates all unique pairs from connected devices and queues them. For 3 devices: 3 pairs. For 4 devices: 6 pairs. For 5: 10 pairs.

### Agent View

When a device is in agent mode, its detail view shows:

```
┌─────────────────────────────────────────────────┐
│ Agent Mode                                       │
│ Connected to conductor: iPad 1                   │
│                                                  │
│ Status: Idle — Waiting for instructions          │
│                                                  │
│  ● Connected to conductor                        │
│  ○ No active test                                │
│                                                  │
│ [Leave Agent Mode]                               │
└─────────────────────────────────────────────────┘
```

During a test:
```
┌─────────────────────────────────────────────────┐
│ Agent Mode — Testing                             │
│ Connected to conductor: iPad 1                   │
│ Testing with: iPad 3                             │
│                                                  │
│ Phase: Latency Burst (3/6)                       │
│ ████████████░░░░░░░░░░░░░░░░░░░░ 42%            │
│                                                  │
│ Live: Ping #47 — 12.3ms                          │
└─────────────────────────────────────────────────┘
```

---

## Implementation Plan

### Phase 1: Multi-Connection Infrastructure

**Files to modify:**
- `ConnectionManager.swift` — No changes needed (already handles one connection, we'll use multiple instances)
- `BonjourService.swift` — Add `mode`, `connections` dictionary, multi-connect logic
- `PeerDevice.swift` — Add `deviceID` for stable identification across connections

**New files:**
- `Services/ConductorService.swift` — Manages fleet, test queue, orchestration logic
- `Models/DeviceConnection.swift` — Wraps ConnectionManager + peer for multi-connection

**Estimated scope:** Medium — refactor connection lifecycle, add multi-connection dictionary

### Phase 2: Orchestration Protocol

**Files to modify:**
- `DiagnosticMessage.swift` — Add orchestration message types
- `DiagnosticEngine.swift` — Handle orchestration messages, forward to ConductorService
- `TestSuiteRunner.swift` — Accept `TestSuiteConfig`, report results via callback

**New files:**
- `Models/TestSuiteConfig.swift` — Configurable test parameters
- `Services/AgentService.swift` — Handles agent-side logic (receive orchestration command, connect to partner, run test, report back)

**Estimated scope:** Medium — new message types, agent-side orchestration handler

### Phase 3: Conductor UI

**New files:**
- `Views/ConductorDashboardView.swift` — Fleet status, pair selection, test queue, results
- `Views/AgentStatusView.swift` — Simple status view for agent devices
- `Views/FleetDeviceCard.swift` — Reusable card for showing a device in the fleet

**Files to modify:**
- `ContentView.swift` — Add `.conductor` and `.agent` detail view cases
- `DeviceListView.swift` — Add fleet section, mode toggle

**Estimated scope:** Medium — new views following existing patterns

### Phase 4: Test Queue & Automation

**Files to modify:**
- `Services/ConductorService.swift` — Add queue management, "Test All Pairs" generation, sequential execution

**Estimated scope:** Small — queue logic on top of Phase 2 orchestration

### Phase 5: Report Aggregation

**Files to modify:**
- `ReportStore.swift` — Tag reports with orchestration source
- `ReportAnalyticsView.swift` — Add conductor-specific views (fleet comparison matrix)

**Estimated scope:** Small — leverage existing report infrastructure

---

## File Summary

### New Files (7)

| File | Purpose |
|---|---|
| `Services/ConductorService.swift` | Fleet management, test queue, orchestration |
| `Services/AgentService.swift` | Agent-side: receive commands, connect to partner, run tests, report back |
| `Models/DeviceConnection.swift` | Wraps ConnectionManager + PeerDevice for multi-connection |
| `Models/TestSuiteConfig.swift` | Configurable test parameters |
| `Views/ConductorDashboardView.swift` | Fleet status, pair queue, results |
| `Views/AgentStatusView.swift` | Agent mode status display |
| `Views/FleetDeviceCard.swift` | Device card for fleet list |

### Modified Files (8)

| File | Changes |
|---|---|
| `BonjourService.swift` | Add `mode` enum, multi-connection support, conductor/agent switching |
| `DiagnosticMessage.swift` | Add orchestration message types |
| `DiagnosticEngine.swift` | Route orchestration messages |
| `TestSuiteRunner.swift` | Accept `TestSuiteConfig`, parameterize test phases |
| `PeerDevice.swift` | Add stable `deviceID` for fleet tracking |
| `ContentView.swift` | Add conductor/agent detail view cases |
| `DeviceListView.swift` | Add fleet section, mode toggle |
| `ReportStore.swift` | Tag reports with orchestration metadata |

---

## Edge Cases & Considerations

### Device Identification
Bonjour service names can collide if two devices have the same custom name. Use the stable `deviceID` (UUID persisted in UserDefaults) exchanged via `peerInfo` for fleet tracking, not the Bonjour service name.

### Connection Limits
iPadOS may limit concurrent Bonjour connections. Testing suggests 5-7 simultaneous TCP connections work reliably. The conductor should connect to devices on-demand rather than maintaining all connections permanently if the fleet is large.

### Test Conflicts
If the conductor tells Device 2 to test with Device 3, but Device 3 is already testing with Device 4, the conductor must queue the request. The `ConductorService` should track device availability:
- `idle` — ready for testing
- `testing` — currently running a test with another device
- `connecting` — in the process of connecting to a test partner

### Network Topology
All devices must be on the same Wi-Fi network (or within Bonjour peer-to-peer range once the multicast entitlement is approved). The conductor doesn't relay data between devices — it only sends commands. The actual test traffic flows directly between the two test devices.

### Conductor Failure
If the conductor app crashes or disconnects during a test, the agent devices should:
1. Complete the current test (if in progress)
2. Cache the report locally
3. Return to standalone mode
4. When a conductor reconnects, offer to sync cached reports

### Backward Compatibility
Devices running the old version (without conductor support) should still work in standalone mode. The conductor should gracefully handle devices that don't respond to `orchestrateTest` messages by marking them as "incompatible."

---

## Test Matrix Generation

For N connected devices, "Test All Pairs" generates N*(N-1)/2 unique pairs:

| Devices | Pairs | Estimated Time (65s per test) |
|---|---|---|
| 2 | 1 | ~1 min |
| 3 | 3 | ~3 min |
| 4 | 6 | ~7 min |
| 5 | 10 | ~11 min |
| 6 | 15 | ~16 min |

The conductor can run pairs in parallel if both devices in a pair are idle. For 4 devices, pairs (A,B) and (C,D) can run simultaneously, reducing wall-clock time.

---

## Priority

This feature builds on the existing codebase without breaking standalone mode. The phased approach means each phase is independently useful:

- **Phase 1** alone gives multi-device connections (useful even without orchestration)
- **Phase 1+2** gives conductor-triggered tests
- **Phase 1+2+3** gives the full conductor UI
- **Phase 4** adds automation (queue, test-all-pairs)
- **Phase 5** adds analytics integration

Recommend starting with Phase 1 and 2 together since the multi-connection infrastructure isn't useful without the orchestration protocol.
