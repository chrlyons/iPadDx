# iPadDx

A diagnostic tool for testing iPad-to-iPad Bonjour connections using Apple's Network.framework with TLS-PSK encryption.

Supports standalone 1:1 testing, or fleet-wide automated testing via Conductor mode across multiple iPads simultaneously.

## Features

### Standalone Mode
- **Bonjour Discovery** -- Automatic peer discovery using `_ipadconn._tcp` service type
- **TLS-PSK Encryption** -- AES-128-GCM pre-shared key encryption on all connections
- **Real-Time Latency** -- Ping/pong measurements every 500ms with live sparkline chart
- **Throughput Testing** -- 10MB data transfer test with MB/s results
- **Signal Quality** -- Derived from latency, jitter, packet loss, and load degradation (Excellent/Good/Fair/Poor)
- **Network Path Info** -- Interface type, expensive/constrained flags, path status
- **Peer Device Info** -- Hardware model, chip family, OS version, device name

### Conductor Mode (Fleet Testing)
- **Multi-Device Orchestration** -- Connect and manage a fleet of iPads from one conductor device
- **Parallel Test Execution** -- Runs multiple device pairs simultaneously, maximizing throughput
- **Automated Pair Generation** -- Test all N x N device combinations with one tap
- **Include Self** -- Conductor can participate in tests alongside fleet agents
- **Re-run Failed Tests** -- Automatically re-queue and run failed pairs
- **Real-Time Fleet Status** -- Live progress, phase info, and status for each agent

### Test Suite (6 Phases)
1. **Latency Burst** -- 100 pings at 50ms intervals measuring round-trip time
2. **Sustained Throughput** -- 10MB transfer measuring data rate
3. **Jitter Measurement** -- 150 samples at 80ms intervals measuring latency variation
4. **Packet Loss Stress** -- 500 pings at 10ms intervals under aggressive conditions
5. **Latency Under Load** -- Latency measurement while saturating the connection
6. **Heavy Load Stress** -- Concurrent data + pings for 15 seconds at maximum stress

### Reporting & Analytics
- **Per-Test Reports** -- Detailed metrics for each test run with device info and grading
- **Error Tracking** -- Failed tests include diagnostic error messages (0 pongs, connection timeouts, peer info failures)
- **CSV Export** -- Individual reports, bulk summaries, and raw data
- **PDF Analytics Report** -- Formatted report with summary stats, per-pair breakdowns, per-chip analysis, grade distribution, and full test data
- **Report Comparison** -- Side-by-side comparison of any two reports
- **Bulk Management** -- Select all/some reports for export or deletion
- **iPad Hardware Catalog** -- Automatic chip family detection via sysctl with fallback to model number lookup

## Requirements

- Two or more iPads running iPadOS 17.0+
- Local Wi-Fi network (internet not required)
- Xcode 15.0+
- Apple Developer account for device deployment

## Setup

1. Open `iPadDx.xcodeproj` in Xcode
2. Select your development team in **Signing & Capabilities**
3. Connect an iPad, select it as the run destination, and press Cmd+R
4. Repeat for additional iPads
5. On first launch, set a name for each device

## Usage

### Standalone (1:1 Testing)
1. Both iPads automatically begin advertising and browsing for peers
2. Tap a discovered device in the sidebar to connect
3. The other device auto-accepts and both show the diagnostic dashboard
4. Use the **Test Suite** to run the full 6-phase test
5. Reports are saved automatically and available in the Reports tab

### Conductor (Fleet Testing)
1. On the conductor iPad, tap **Enable Conductor Mode** in the sidebar
2. Other iPads will appear in the discovered devices list -- tap to add them to the fleet
3. Each device automatically enters Agent mode when added
4. Toggle **Include This Device** to add the conductor to the test pool
5. Tap **All Pairs** to generate every device combination, or **Add Pair** for specific pairs
6. Tap **Run Queue** to execute all tests with parallel scheduling
7. Results appear in the collapsible **Recent Results** section
8. Failed tests can be re-run with the **Re-run Failed** button
9. Export analytics as a PDF report from the **Analytics** tab

## Architecture

Built with SwiftUI and Apple's Network.framework (`NWBrowser`, `NWListener`, `NWConnection`) with TLS-PSK encryption.

```
iPadDx/
├── iPadDxApp.swift
├── Models/
│   ├── DiagnosticMessage.swift       # Wire protocol (21 message types)
│   ├── DiagnosticMetrics.swift       # Observable metric model + signal quality
│   ├── PeerDevice.swift              # Peer device model with roles
│   ├── DeviceConnection.swift        # Fleet agent connection wrapper
│   ├── TestReport.swift              # Report structure + iPad hardware catalog
│   ├── TestSuiteConfig.swift         # Configurable test parameters
│   └── ReportEntity.swift            # SwiftData persistence model
├── Networking/
│   ├── BonjourService.swift          # NWListener + NWBrowser + mode management
│   ├── ConnectionManager.swift       # NWConnection + TLS-PSK + length-prefix framing
│   └── DiagnosticEngine.swift        # Message routing, ping loop, peer info exchange
├── Services/
│   ├── AgentService.swift            # Agent-side test orchestration
│   ├── ConductorService.swift        # Fleet management + parallel test scheduling
│   ├── TestSuiteRunner.swift         # 6-phase test suite + grading algorithm
│   ├── ReportStore.swift             # SwiftData persistence + CSV/analytics export
│   ├── AnalyticsReportRenderer.swift # PDF report generation
│   ├── DeviceIdentifier.swift        # Hardware/chip detection via sysctl
│   └── SystemMonitor.swift           # CPU/memory/battery/thermal via Mach kernel
└── Views/
    ├── ContentView.swift             # NavigationSplitView root
    ├── DeviceListView.swift          # Peer discovery sidebar
    ├── DiagnosticDashboardView.swift  # Real-time metrics dashboard
    ├── TestSuiteView.swift           # Test suite execution UI
    ├── ConductorDashboardView.swift  # Fleet management + queue controls
    ├── FleetDeviceCard.swift         # Agent device card + self device card
    ├── AgentStatusView.swift         # Agent mode status display
    ├── ReportListView.swift          # Report browsing + bulk actions
    ├── ReportDetailView.swift        # Individual report detail
    ├── ReportComparisonView.swift    # Side-by-side report comparison
    ├── ReportAnalyticsView.swift     # Analytics dashboard + charts
    ├── ConnectionStatusBadge.swift   # Status dot indicator
    ├── MetricGaugeView.swift         # Metric card component
    └── ThroughputTestView.swift      # Throughput test UI
```

## Entitlements

| Entitlement | Purpose | Status |
|---|---|---|
| Multicast Networking | Peer-to-peer discovery, offline local Wi-Fi | Approved |
| User Assigned Device Name | Read user's custom device name on iOS 16+ | Pending |

The app works without the device name entitlement -- names are set manually in-app as a fallback.

## Protocol

Devices communicate over TLS-PSK encrypted TCP using length-prefixed JSON framing (4-byte big-endian length + JSON payload).

### Message Types

| Message | Direction | Purpose |
|---|---|---|
| `ping` / `pong` | Both | Latency probes (diagnostic heartbeat) |
| `peerInfo` | Both | Exchange device name, model, chip, OS, stable ID |
| `throughputStart` / `throughputData` / `throughputAck` | A -> B | Throughput measurement |
| `testPing` / `testPong` | A -> B -> A | Test suite latency probes (sequenced) |
| `testSuiteStatus` | A -> B | Notify responder of test phase |
| `reportSync` | Both | Share test reports between devices |
| `roleAssignment` | Conductor -> Agent | Assign agent role to fleet device |
| `orchestrateTest` | Conductor -> Agent | Command agent to run/respond to test |
| `orchestrationStatus` | Agent -> Conductor | Report test progress/completion/failure |
| `orchestrationReport` | Agent -> Conductor | Send completed test report |
| `orchestrationCancel` | Conductor -> Agent | Cancel in-progress test |
| `disconnect` | Both | Graceful disconnect |

## Grading Algorithm

Tests are scored on a 12-point scale across 4 dimensions:

| Metric | 3 pts | 2 pts | 1 pt | 0 pts |
|---|---|---|---|---|
| Avg Latency | < 10ms | < 30ms | < 100ms | >= 100ms |
| Avg Jitter | < 5ms | < 15ms | < 30ms | >= 30ms |
| Packet Loss | < 1% | < 5% | < 10% | >= 10% |
| Load Degradation | <= 0% | < 50% | < 100% | >= 100% |

- **Excellent**: 9-12 points
- **Good**: 6-8 points
- **Fair**: 3-5 points
- **Poor**: 0-2 points (or 0 latency + jitter samples = test failed)

## License

Private project.
