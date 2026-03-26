# iPadConnection

A diagnostic tool for testing and troubleshooting Bonjour device-to-device connections between two iPads. Measures real-time latency, throughput, signal quality, and network path information.

## Features

- **Bonjour Discovery** -- Automatic peer discovery using `_ipadconn._tcp` service type
- **Real-Time Latency** -- Ping/pong measurements every 500ms with live sparkline chart
- **Throughput Testing** -- On-demand 1MB data transfer test with MB/s results
- **Signal Quality** -- Derived from latency stability (Excellent/Good/Fair/Poor)
- **Network Path Info** -- Interface type, expensive/constrained flags, path status
- **Peer Device Info** -- Hardware model, OS version, device name
- **Auto-Connect** -- Receiving device automatically accepts and shows diagnostics

## Requirements

- Two iPads running iPadOS 17.0+
- Both devices on the same Wi-Fi network (or peer-to-peer with multicast entitlement)
- Xcode 15.0+
- Apple Developer account for device deployment

## Setup

1. Open `iPadConnection.xcodeproj` in Xcode
2. Select your development team in **Signing & Capabilities**
3. Connect an iPad, select it as the run destination, and press Cmd+R
4. Repeat for the second iPad
5. On first launch, set a name for each device

## Usage

1. Both iPads automatically begin advertising and browsing for peers
2. Tap a discovered device in the sidebar to connect
3. The other device auto-accepts and both show the diagnostic dashboard
4. Use the **Run Test** button to measure throughput
5. Use the menu (top-right) to disconnect, change device name, or toggle advertising/browsing

## Architecture

Built with SwiftUI and Apple's Network framework (`NWBrowser`, `NWListener`, `NWConnection`).

```
iPadConnection/
├── iPadConnectionApp.swift           # App entry point
├── Models/
│   ├── DiagnosticMessage.swift       # Wire protocol (ping/pong/throughput/peerInfo)
│   ├── DiagnosticMetrics.swift       # Observable metric model
│   └── PeerDevice.swift              # Peer device model
├── Networking/
│   ├── BonjourService.swift          # NWListener + NWBrowser management
│   ├── ConnectionManager.swift       # NWConnection lifecycle + length-prefix framing
│   └── DiagnosticEngine.swift        # Ping loop, throughput test, metric computation
└── Views/
    ├── ContentView.swift             # NavigationSplitView root + name prompt
    ├── DeviceListView.swift          # Peer discovery sidebar
    ├── DiagnosticDashboardView.swift  # Real-time metrics dashboard with Charts
    ├── ConnectionStatusBadge.swift    # Status dot indicator
    ├── MetricGaugeView.swift         # Metric card component
    └── ThroughputTestView.swift      # Throughput test UI
```

## Entitlements (Optional)

These entitlements enhance the app but require Apple approval:

| Entitlement | Purpose | Status | How to Request |
|---|---|---|---|
| Multicast Networking | Peer-to-peer discovery without Wi-Fi | Pending (RHXF823X24) | [Request Form](https://developer.apple.com/contact/request/networking-multicast) |
| User Assigned Device Name | Read the user's custom device name | Pending | [Request Form](https://developer.apple.com/contact/request/device-name) |

The app works without these entitlements when both iPads are on the same Wi-Fi network. Device names are set manually in-app as a fallback.

### Once approved:

- [ ] Enable Multicast Networking on App ID in [Certificates, Identifiers & Profiles](https://developer.apple.com/account)
- [ ] Enable User Assigned Device Name on App ID
- [ ] Add entitlements back to `iPadConnection/iPadConnection.entitlements`
- [ ] Remove manual device name prompt fallback (optional)

## Protocol

Devices communicate over TCP using a simple length-prefixed JSON protocol:

| Message | Direction | Purpose |
|---|---|---|
| `ping` | A -> B | Latency probe with timestamp |
| `pong` | B -> A | Echo back original timestamp |
| `peerInfo` | Both | Exchange device name, model, OS |
| `throughputStart` | A -> B | Begin throughput measurement |
| `throughputData` | A -> B | Data chunks for throughput test |
| `throughputAck` | A -> B | Signal test completion with timing |

## License

Private project.
