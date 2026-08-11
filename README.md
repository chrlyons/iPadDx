# iPadDx

A diagnostic tool for testing iPad-to-iPad Bonjour connections using Apple's Network.framework with TLS-PSK encryption.

Supports standalone 1:1 testing, or fleet-wide automated testing via Conductor mode across multiple iPads simultaneously.

## Features

### Standalone Mode
- **Bonjour Discovery** -- Automatic peer discovery using `_ipadconn._tcp` service type
- **TLS-PSK Encryption** -- AES-128-GCM pre-shared key encryption on all connections
- **Real-Time Latency** -- Ping/pong measurements every 500ms with live sparkline chart
- **Throughput Testing** -- Real 10MB payload transfer; the receiving device counts the bytes and reports the rate
- **Signal Quality** -- Derived from latency, jitter and packet loss (Excellent/Good/Fair/Poor)
- **Network Path Info** -- Interface type, expensive/constrained flags, path status
- **Peer Device Info** -- Hardware model, chip family, OS version, device name

### Conductor Mode (Fleet Testing)
- **Multi-Device Orchestration** -- Connect and manage a fleet of iPads from one conductor device
- **Parallel Test Execution** -- Runs multiple device pairs simultaneously, maximizing throughput
- **Automated Pair Generation** -- Test all ordered device pairs, N x (N-1), with one tap
- **Include Self** -- Conductor can participate in tests alongside fleet agents
- **Re-run Failed Tests** -- Automatic retry of transient failures, plus a manual re-run button
- **Real-Time Fleet Status** -- Live progress, phase info, and status for each agent

### Test Suite (7 Phases)
1. **DNS Resolution** -- Measures mDNS discovery time for the peer's Bonjour service via a fresh `NWBrowser`
2. **Latency Burst** -- 100 pings at 50ms intervals measuring round-trip time
3. **Sustained Throughput** -- 10MB of real payload in 32KB chunks; the receiver counts the bytes that
   arrive and acks its own measurement back to the sender
4. **Jitter Measurement** -- 150 samples at 80ms intervals measuring variation between consecutive probes
5. **Packet Loss Stress** -- 500 pings at 10ms intervals under aggressive conditions
6. **Latency Under Load** -- Latency measured while a real payload stream saturates the link
7. **Heavy Load Stress** -- Three concurrent real payload streams + 75 latency probes for 15 seconds

Throughput is reported as **application payload bytes per second**. Messages are framed as JSON, so
payload bytes are base64-encoded on the wire and the link actually carries roughly 1.33x the reported
figure. The framing is identical for every transport, so cross-device and cross-bridge comparisons
remain like-for-like.

### Reporting & Analytics
- **Per-Test Reports** -- Detailed metrics for each test run with device info and grading
- **Error Tracking** -- Failed tests include diagnostic error messages (0 pongs, connection timeouts, peer info failures)
- **CSV Export** -- Individual reports, bulk summaries, and raw data
- **PDF Analytics Report** -- Formatted report with summary stats, per-pair breakdowns, per-chip analysis, grade distribution, and full test data
- **Report Comparison** -- Side-by-side comparison of any two reports
- **Trend Detection** -- Linear-regression trends per metric and per device pair, with confidence
- **Bulk Management** -- Select all/some reports for export or deletion
- **iPad Hardware Catalog** -- Automatic chip family detection via sysctl with fallback to model number lookup

## Requirements

- Two or more iPads running iPadOS 17.0+
- Local Wi-Fi network (internet not required)
- Xcode 15.0+
- Apple Developer account for device deployment

## Setup

Capacitor and Cordova are integrated with CocoaPods, so `iPadDx.xcworkspace` and
`Pods/` are **generated, not committed**. A fresh clone has neither — you must run the
dependency step first, or Xcode and `xcodebuild` will fail to resolve the `Cordova`
and `Capacitor` modules.

1. Install dependencies: `make setup` (Homebrew tools), then `make bridges`
   — or, at minimum, `make pods` to generate `iPadDx.xcworkspace`
2. Open **`iPadDx.xcworkspace`** in Xcode (`make open`).
   Opening `iPadDx.xcodeproj` directly will not build: the pods are not in it
3. Select your development team in **Signing & Capabilities**
4. Connect an iPad, select it as the run destination, and press Cmd+R
5. Repeat for additional iPads
6. On first launch, set a name for each device

Command line: `make build-sim`, `make build` (device) and `make test` all use the
workspace and will tell you to run `make pods` if it is missing.

## Usage

### Standalone (1:1 Testing)
1. Both iPads automatically begin advertising and browsing for peers
2. Tap a discovered device in the sidebar to connect
3. The other device auto-accepts and both show the diagnostic dashboard
4. On the controller device, use the **Test Suite** to run the full 7-phase test
   (tests are initiated from the controller; the responder shows a status card)
5. When the run finishes, tap **Save & Sync** to store the report and send it to the peer;
   saved reports appear in the Reports tab

### Bridge Transport Comparison

Cordova, React Native, Flutter and Capacitor overhead is measured by running the suite through the real
framework runtime on **both** devices. That requires a fresh connection stood up on each side, which only
Conductor mode can orchestrate, so bridge comparison is available for **agent-to-agent pairs only**.
Standalone runs and any pair that includes the conductor itself always use the native transport, and their
reports record exactly that — a report is never labelled with a bridge that did not carry its bytes.

### Conductor (Fleet Testing)
1. On the conductor iPad, tap **Enable Conductor Mode** in the sidebar
2. Other iPads appear under **Nearby Devices** in the sidebar -- tap to add them to the fleet
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
│   ├── DiagnosticMessage.swift       # Wire protocol (19 message types)
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
│   └── SystemMonitor.swift           # CPU/memory via Mach; battery via UIDevice, thermal via ProcessInfo
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
| `throughputStart` / `throughputData` | A -> B | Throughput transfer (`throughputData` carries real payload bytes) |
| `throughputAck` | B -> A | Receiver's measurement: bytes counted and elapsed time |
| `testPing` / `testPong` | A -> B -> A | Test suite latency probes (sequenced) |
| `testSuiteStatus` | A -> B | Notify responder of test phase |
| `reportSync` | Both | Share test reports between devices |
| `roleAssignment` | Conductor -> Agent | Assign agent role to fleet device |
| `orchestrateTest` | Conductor -> Agent | Command agent to run/respond to test |
| `orchestrationStatus` | Agent -> Conductor | Report test progress/completion/failure |
| `orchestrationReport` | Agent -> Conductor | Send completed test report |
| `orchestrationCancel` | Conductor -> Agent | Cancel in-progress test |
| `agentCapabilities` | Agent -> Conductor | Advertise supported bridge transports, app and iOS version |
| `liveMetrics` | Responder -> Controller | CPU / memory / thermal broadcast every 2s during a test |
| `responderMetrics` | Responder -> Controller | Responder-side system metrics after the test |
| `disconnect` | Both | Graceful disconnect |

## Grading Algorithm

Tests are scored on a 12-point scale across 4 dimensions:

| Metric | 3 pts | 2 pts | 1 pt | 0 pts |
|---|---|---|---|---|
| Avg Latency | < 10ms | < 30ms | < 100ms | >= 100ms |
| Avg Jitter | < 5ms | < 15ms | < 30ms | >= 30ms |
| Packet Loss | < 1% | < 5% | < 10% | >= 10% |
| Load Degradation | <= 0% | < 50% | < 100% | >= 100% |

Only dimensions that actually produced samples are scored; the total is then normalised onto the 12-point scale. A phase that is disabled or that collects nothing contributes nothing — it cannot raise the grade.

- **Excellent**: 9-12 points
- **Good**: 6-8 points
- **Fair**: 3-5 points
- **Poor**: 0-2 points (or 0 latency + jitter samples = test failed)

## License

This project is licensed under the [MIT License](LICENSE).
