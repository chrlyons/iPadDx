# Bridge Overhead Testing

> **Status:** Implemented. All phases complete. See [Shortcuts & Limitations](#shortcuts--limitations) for deviations from the original design.

## Problem Statement

iPadDx currently tests device-to-device connections using native Swift directly on Apple's Network.framework. This gives accurate measurements of the raw network path, but real-world apps like Assess 2.0 don't talk to Network.framework directly — they go through a bridge layer (Cordova, React Native, Flutter, etc.) that adds its own overhead to every message.

When a clinician reports "the connection is slow," we can't tell if the problem is the network or the bridge. iPadDx needs to test through the same bridge the target app uses so we measure what users actually experience — not an idealized version of it.

**Goal:** Run real test traffic through real bridge implementations so reports reflect actual app-level connection quality, not just network-level quality.

---

## Bridge Types

All five bridges ship in a single build. Each is selectable in the UI.

| Bridge ID | Technology | Target App Example | Status |
|-----------|-----------|-------------------|--------|
| `native` | Direct Swift / Network.framework | iPadDx itself | Baseline |
| `cordova` | JavaScriptCore + Cordova exec/callback pipeline | Assess 2.0 | Implemented |
| `reactnative` | JavaScriptCore + RN MessageQueue/BatchedBridge | — | Implemented |
| `flutter` | StandardMethodCodec binary serialization + thread dispatch | — | Implemented (see shortcuts) |
| `capacitor` | WKWebView + postMessage IPC | — | Implemented |

The `native` bridge is always available and cannot be deselected (it's the baseline for comparison).

---

## Architecture

### Networking Layer Abstraction

`ConnectionManager` delegates all network operations to a `TransportProvider`. It no longer touches `NWConnection` directly.

```
┌─────────────────────────────────────────────────────────┐
│                    TestSuiteRunner                       │
│              (unchanged — runs test phases)              │
└──────────────────────┬──────────────────────────────────┘
                       │
┌──────────────────────▼──────────────────────────────────┐
│                  ConnectionManager                       │
│       (message encode/decode, state machine)             │
│       Delegates send/receive to TransportProvider        │
└──────────────────────┬──────────────────────────────────┘
                       │
     ┌─────────────────┼──────────────────────────┐
     │                 │                          │
┌────▼────┐  ┌────────▼────────┐  ┌──────────────▼──────────────┐
│ Native  │  │    Cordova      │  │  ReactNative / Flutter /    │
│Transport│  │   Transport     │  │  Capacitor Transports       │
│         │  │                 │  │                             │
│NWConn   │  │JSContext→NWConn │  │JSContext/WKWebView/Codec    │
│(direct) │  │(exec/callback)  │  │      →NWConn               │
└─────────┘  └─────────────────┘  └─────────────────────────────┘
```

### TransportProvider Protocol

File: `iPadDx/Networking/TransportProvider.swift`

```swift
protocol TransportProvider: AnyObject {
    var bridgeID: String { get }
    var bridgeLabel: String { get }

    func connect(to endpoint: NWEndpoint, queue: DispatchQueue)
    func accept(_ connection: NWConnection, queue: DispatchQueue)
    func send(_ data: Data, completion: @escaping (NWError?) -> Void)
    func startReceiving(handler: @escaping (Data) -> Void,
                        onEOF: @escaping () -> Void,
                        onError: @escaping (NWError) -> Void)
    func disconnect()

    var currentPath: NWPath? { get }
    var onStateChange: ((TransportState) -> Void)? { get set }
}
```

### Bridge Transport Implementations

**CordovaTransport** (`iPadDx/Networking/CordovaTransport.swift`)
- Embeds a real `JSContext` (JavaScriptCore framework)
- JS replicates the actual Cordova pipeline: `cordova.exec()` → command queue → `fetchMessages()` batch flush → JSON serialize/deserialize → `callbackFromNative()` dispatch
- Models `CDVPlugin`/`CDVCommandDelegate` callback patterns
- Send: Swift → base64 → JS exec() → command queue → JSON serialize batch → JSON parse → callback → base64 → Swift → NWConnection
- Receive: NWConnection → Swift → base64 → JS event dispatch → JSON serialize/parse → callback → base64 → Swift

**ReactNativeTransport** (`iPadDx/Networking/ReactNativeTransport.swift`)
- Embeds a real `JSContext` (JavaScriptCore framework)
- JS replicates RN's `MessageQueue`/`BatchedBridge` architecture: module registry with numeric moduleIDs/methodIDs, `enqueueNativeCall()` batching, `flushedQueue()` JSON serialization, `invokeCallback()` dispatch
- Models the bridge (legacy) architecture, not JSI/TurboModules — the bridge is the path that adds measurable overhead

**FlutterTransport** (`iPadDx/Networking/FlutterTransport.swift`)
- Implements Flutter's `StandardMethodCodec` binary serialization in Swift (matching the actual encoding format: type tags, variable-length size encoding, method call and envelope encoding)
- Adds double `DispatchQueue` thread hop simulating Flutter's UI thread → platform thread → UI thread context switches
- **Does NOT embed the Dart VM** — see [Shortcuts](#shortcuts--limitations)

**CapacitorTransport** (`iPadDx/Networking/CapacitorTransport.swift`)
- Embeds a real `WKWebView` — the actual technology Capacitor uses
- Cross-process IPC via `postMessage` / `WKScriptMessageHandler` / `evaluateJavaScript` is genuine (WebKit process boundary)
- JS replicates `Capacitor.toNative()`/`fromNative()` pipeline with callbackId registry, plugin call serialization, and event dispatch

---

## Test Configuration

### TestSuiteConfig

```swift
struct TestSuiteConfig: Codable {
    // ... existing phase toggles ...
    var bridgeTransports: [String] = ["native"]
}
```

### TestRun Model

Each queue entry is a pair + bridge combination:

```swift
struct TestRun: Identifiable, Equatable {
    let id: UUID
    let pair: TestPair
    let bridgeTransport: String
    var label: String  // "A (M4) → B (M2) [cordova]"
}
```

### Queue Ordering

When multiple bridges are selected, the queue interleaves bridges across pairs to prevent thermal throttling from back-to-back runs on the same devices:

```
A→B [native]
A→C [native]
A→B [cordova]    ← A and B have had a break
B→C [native]
A→C [cordova]
B→C [cordova]
```

---

## UI

### Standalone Mode (TestSuiteView)

Bridge transport toggle section below phase toggles. Native is always on. Each additional bridge adds one more sequential run. Summary shows "This test will run 2x (once per bridge)".

### Conductor Mode (ConductorDashboardView)

Same bridge toggle section in queue controls. `generateAllPairs()` creates `P * B` TestRuns. Manual pair addition creates one TestRun per selected bridge. Queue list shows bridge variant as a tag on non-native runs.

---

## Report Changes

- `TestReport.bridgeTransport: String?` — nil for old reports (backward compatible)
- `ReportEntity.bridgeTransport: String = "native"` — column default handles migration
- `ReportSummary.bridgeTransport: String` — always populated
- CSV exports include bridge column (summary, analytics with comparison sections)
- PDF analytics includes "Bridge Overhead Analysis" section with delta vs native
- Report list and analytics views have bridge filter picker

---

## Orchestration Protocol

- `orchestrateTest(..., bridgeTransport: String = "native")` — agents create ConnectionManager with specified bridge
- `agentCapabilities(supportedBridges: [String])` — sent on agent mode entry, conductor stores on DeviceConnection
- `DeviceConnection.supportedBridges: [String] = ["native"]`

---

## Execution Flow

### Standalone Mode

```
User selects bridges → taps Run Test
  → for each bridge (sequential):
      1. Set bridgeTransportOverride on runner
      2. Run full suite (warm-up + all phases)
      3. Save report (intermediate reports saved immediately)
      4. Reset runner, 2-second settle delay
  → Show results
```

### Conductor Mode

```
Conductor selects bridges → All Pairs → Run Queue
  → Scheduler picks next TestRun where both devices idle
  → Sends orchestrateTest(..., bridgeTransport) to agents
  → Agent creates ConnectionManager(bridgeTransport:) → correct TransportProvider
  → Test runs through bridge → report includes bridgeTransport
  → Report returned to conductor
```

---

## Data Migration

- `TestReport.bridgeTransport` is `String?` — old JSON decodes to nil
- `ReportEntity.bridgeTransport` defaults to `"native"` via SwiftData column default
- All queries use `?? "native"` fallback
- `orchestrateTest` has `bridgeTransport: String = "native"` default — old agents ignore the field

---

## Design Decisions

1. **Bridge on both sides.** Both controller AND responder use the bridge transport. Matches real-world usage.

2. **JSContext lifecycle.** Each transport instance creates its own JSContext. A new transport is created per ConnectionManager, so each test run gets a fresh context. This isolates bridge state between runs.

3. **Single app build.** All bridge transports ship in one build. Binary size is not a concern for an internal diagnostic tool.

4. **Agents must be pre-installed.** All iPads need the same build. `agentCapabilities` handles version mismatches.

5. **Warm-up per bridge run.** Each `runFullSuite()` call includes its own warm-up. Standalone mode calls it once per bridge.

---

## Shortcuts & Limitations

These are deviations from the original design or areas where the implementation approximates rather than replicates the real-world bridge.

### FlutterTransport: No Dart VM

The original design called for embedding the Dart runtime. Flutter's engine is a compiled C++ binary (~40MB) that requires the Flutter SDK to build. Embedding it would require adding Flutter as a framework dependency.

**What we do instead:** Replicate the two dominant overhead sources:
1. **StandardMethodCodec binary serialization** — implemented in Swift matching Flutter's actual encoding format (type tags, variable-length size encoding, method call and envelope framing)
2. **Platform thread dispatch** — double `DispatchQueue` hop simulating Flutter's UI thread → platform thread → UI thread context switches

**What's missing:** The actual Dart VM boundary crossing. In a real Flutter app, data crosses from native (Objective-C/Swift) into the Dart isolate and back. Our implementation measures serialization + thread dispatch but not the Dart runtime overhead itself.

**Impact:** FlutterTransport overhead measurements will underestimate real Flutter app overhead. The serialization and thread dispatch are the largest contributors, but the Dart VM adds additional cost.

### CordovaTransport: Simplified Bridge Shim

The JS shim faithfully models Cordova's `exec()` → command queue → `fetchMessages()` → callback pipeline. However, it does not include:
- The full CDVPlugin class hierarchy
- CDVInvokedUrlCommand parsing
- Actual Cordova plugin lifecycle (pluginInitialize, onReset, etc.)
- WKWebView message handler bridge (real modern Cordova uses WKWebView, our implementation uses JSContext directly)

**Impact:** JSContext is faster than WKWebView for the same JS operations (no cross-process IPC). Real Cordova overhead on modern iOS (WKWebView-based) would be higher than what CordovaTransport measures. The CapacitorTransport, which uses real WKWebView, gives a better approximation of the WKWebView process boundary cost.

### ReactNativeTransport: Bridge Architecture Only

Models the legacy bridge (MessageQueue/BatchedBridge) architecture. Does not model the newer JSI/TurboModules architecture, which bypasses JSON serialization with direct C++ JSI bindings. Apps using the new architecture would have significantly lower bridge overhead.

### No "Bridge One Side Only" Toggle

The design mentions a toggle to bridge only one side for deeper debugging. This was not implemented — both sides always use the same bridge transport.

### Standalone Progress UI

The design calls for "Run 1/2 — Native" progress display during multi-bridge execution. The current implementation runs bridges sequentially but doesn't show which bridge run is active in the progress UI.

---

## Files

| File | Role |
|---|---|
| `Networking/TransportProvider.swift` | Protocol + BridgeRegistry + TransportState |
| `Networking/NativeTransport.swift` | Direct NWConnection (baseline) |
| `Networking/CordovaTransport.swift` | JavaScriptCore + Cordova bridge |
| `Networking/ReactNativeTransport.swift` | JavaScriptCore + RN MessageQueue |
| `Networking/FlutterTransport.swift` | StandardMethodCodec + thread dispatch |
| `Networking/CapacitorTransport.swift` | WKWebView + postMessage IPC |
| `Networking/ConnectionManager.swift` | Delegates to TransportProvider |
| `Models/TestReport.swift` | `bridgeTransport: String?` field |
| `Models/TestSuiteConfig.swift` | `bridgeTransports: [String]` field |
| `Models/DiagnosticMessage.swift` | Updated orchestrateTest + agentCapabilities |
| `Models/DeviceConnection.swift` | `supportedBridges` field |
| `Models/ReportEntity.swift` | `bridgeTransport` column |
| `Services/ConductorService.swift` | TestRun queue, bridge-aware execution |
| `Services/AgentService.swift` | Creates ConnectionManager with bridge |
| `Services/AnalyticsReportRenderer.swift` | PDF bridge overhead section |
| `Views/TestSuiteView.swift` | Bridge toggle UI, multi-bridge execution loop |
| `Views/ConductorDashboardView.swift` | Bridge toggle UI, queue display |
