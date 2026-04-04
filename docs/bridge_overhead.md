# Bridge Overhead Testing

## Problem Statement

iPadDx tests device-to-device connections using native Swift on Network.framework. Real-world apps like Assess 2.0 go through a bridge layer (Cordova, React Native, Flutter, etc.) that adds overhead to every message. iPadDx tests through the same real bridge runtimes so reports reflect actual app-level connection quality.

---

## Bridge Types

All five bridges ship in a single build, all running **real framework runtimes** (no simulations). Each is selectable in the UI.

| Bridge ID | Technology | Target App Example |
|-----------|-----------|-------------------|
| `native` | Direct Swift / Network.framework | iPadDx itself (baseline) |
| `cordova` | WKWebView + real cordova.js + CDVPlugin + CDVPluginResult | Assess 2.0 |
| `reactnative` | RCTBridge + Hermes engine + ObjC RCT_EXPORT_MODULE | — |
| `flutter` | FlutterEngine + FlutterMethodChannel + AOT Dart isolate | — |
| `capacitor` | CAPBridgeViewController + CAPPlugin + WKWebView IPC | — |

The `native` bridge is always available and cannot be deselected (it's the baseline for comparison).

### Overhead Characteristics

| Framework | Process Boundary | Serialization | Binary Data | Dominant Overhead |
|---|---|---|---|---|
| **Native** | None | None | Raw bytes | Baseline |
| **Flutter** | None (in-process) | Binary codec | Uint8List (zero-copy) | Thread dispatch |
| **React Native** | None (in-process) | JSON + batching | Base64 | Batch interval (~5ms) |
| **Cordova** | Yes (WKWebView) | JSON | Base64 only | IPC + JSON + Base64 |
| **Capacitor** | Yes (WKWebView) | JSON | Base64 only | IPC + JSON + Base64 |

---

## Architecture

### Networking Layer

`ConnectionManager` delegates all network operations to a `TransportProvider`.

```
┌──────────────────────────────────────────────┐
│              TestSuiteRunner                  │
└──────────────────┬───────────────────────────┘
                   │
┌──────────────────▼───────────────────────────┐
│            ConnectionManager                  │
│     (encode/decode, state machine)            │
│     Delegates send/receive to transport       │
└──────────────────┬───────────────────────────┘
                   │
    ┌──────────────┼──────────────┬──────────────┐
    │              │              │              │
┌───▼───┐  ┌──────▼──────┐  ┌───▼────┐  ┌──────▼──────┐
│Native │  │  Cordova    │  │Flutter │  │  Capacitor  │
│       │  │  (WKWebView │  │(Engine │  │  (CAPBridge │
│NWConn │  │  + CDVPlugin│  │+ Dart) │  │  + WKWebView│
│direct │  │  + cordova. │  │        │  │  + CAPPlugin│
│       │  │  js)        │  │        │  │             │
└───────┘  └─────────────┘  └────────┘  └─────────────┘
                   │
            ┌──────▼──────┐
            │ReactNative  │
            │(RCTBridge   │
            │+ Hermes     │
            │+ ObjC NM)   │
            └─────────────┘
```

### TransportProvider Protocol

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

---

## Bridge Implementations

### Cordova (WKWebView + CDVPlugin)

- Real WKWebView running real `cordova.js` (from CapacitorCordova)
- Real `CDVPlugin` subclass (`CordovaEchoPlugin`) with `CDVPluginResult` + `CDVInvokedUrlCommand`
- Real `CDVCommandDelegate` implementation delivering results via `evaluateJavaScript(nativeCallback)`
- `WKScriptMessageHandler` receives `cordova.exec()` calls from JS

```
Send: Swift → base64 → WKWebView evaluateJavaScript("echoBridge()") → [WebKit IPC]
  → cordova.exec() → webkit.messageHandlers.bridge.postMessage() → [WebKit IPC]
  → WKScriptMessageHandler → CDVInvokedUrlCommand → CordovaEchoPlugin.echo()
  → CDVPluginResult → evaluateJavaScript(nativeCallback) → [WebKit IPC]
  → JS callback → base64 → Swift → NWConnection
```

### React Native (RCTBridge + Hermes)

- Real `RCTBridge` running the Hermes JS engine (AOT bytecode)
- Real ObjC native module (`BridgeEchoModule.m`) with `RCT_EXPORT_MODULE()` + `RCT_EXPORT_METHOD()`
- Built in separate Xcode project to avoid `use_frameworks!` conflict (see [Build Notes](#react-native-separate-build-project))
- Pre-bundled `main.jsbundle` via Metro, `hermes.xcframework` embedded

```
Send: Swift → base64 → bridge.enqueueJSCall("BridgeEchoModule", "echo")
  → Hermes JS thread → BatchedBridge callable module dispatch
  → NativeModules.BridgeEchoModule.echo() → RCTBatchedBridge
  → ObjC BridgeEchoModule.echo() → resolve(base64)
  → ReactNativeBridgeNotifier → Swift callback → NWConnection
```

### Flutter (FlutterEngine + Dart)

- Real `FlutterEngine` running a headless Dart isolate (AOT compiled)
- Real `FlutterMethodChannel` with `StandardMethodCodec` binary serialization
- Dart handler echoes data back through the channel

```
Send: Swift → FlutterStandardTypedData → channel.invokeMethod("echo")
  → StandardMethodCodec encode → Dart VM thread dispatch
  → Dart MethodChannel handler → echo Uint8List back
  → StandardMethodCodec encode result → platform thread callback → Swift → NWConnection
```

### Capacitor (CAPBridgeViewController + CAPPlugin)

- Real `CAPBridgeViewController` with real Capacitor native-bridge.js
- Real `CAPPlugin` subclass (`BridgeEchoPlugin`) registered via `bridge.registerPluginInstance()`
- Cross-process WKWebView IPC (WebContent process boundary)

```
Send: Swift → base64 → evaluateJavaScript("echoBridge()") → [WebKit IPC]
  → JS Capacitor.Plugins.BridgeEchoPlugin.echo() → Capacitor.toNative() → [WebKit IPC]
  → WKScriptMessageHandler → CapacitorBridge → BridgeEchoPlugin.echo()
  → CAPPluginCall.resolve() → evaluateJavaScript(fromNative) → [WebKit IPC]
  → JS callback → Swift → NWConnection
```

---

## Test Configuration

### TestSuiteConfig

```swift
struct TestSuiteConfig: Codable {
    // ... phase toggles ...
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

When multiple bridges are selected, the queue interleaves bridges across pairs to prevent thermal throttling:

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

Bridge transport toggle section below phase toggles. Native is always on. Each additional bridge adds one more sequential run.

### Conductor Mode (ConductorDashboardView)

Same bridge toggle section. `generateAllPairs()` creates `P * B` TestRuns. Queue list shows bridge variant as a tag on non-native runs.

---

## Execution Flow

### Standalone Mode

```
User selects bridges → taps Run Test
  → for each bridge (sequential):
      1. Set bridgeTransportOverride on runner
      2. Run full suite (warm-up + all phases)
      3. Save report
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

### Orchestration Protocol

- `orchestrateTest(..., bridgeTransport: String = "native")` — agents create ConnectionManager with specified bridge
- `agentCapabilities(supportedBridges: [String])` — sent on agent mode entry, conductor stores on DeviceConnection
- `DeviceConnection.supportedBridges: [String] = ["native"]`

---

## Reports & Storage

### Report Schema

- `TestReport.bridgeTransport: String?` — nil for old reports (backward compatible)
- `ReportEntity.bridgeTransport: String = "native"` — column default handles migration
- `ReportSummary.bridgeTransport: String` — always populated

### ReportStore Queries

All queries operate on the in-memory `summaries` array:

```swift
func summaries(forBridge bridge: String) -> [ReportSummary]
func summaries(forChipPair local: String, remote: String, bridge: String? = nil) -> [ReportSummary]
func availableBridgeTransports() -> [String]
func bridgeComparison(local: String, remote: String) -> [BridgeComparisonRow]
```

### CSV Export

- **Single report** — bridge transport line in header
- **Summary CSV** — "Bridge Transport" column between Remote OS and Grade
- **Analytics CSV** — bridge comparison section (per-bridge metrics with delta vs native), per-pair and per-chip breakdowns with bridge dimension (only when multiple bridges present)

### PDF Analytics

`AnalyticsReportRenderer` adds a "Bridge Overhead Analysis" section when multiple bridges are present: per-bridge comparison table with delta vs native baseline, per-pair bridge breakdown.

### View Integration

- **ReportListView** — bridge filter picker, bridge tag on non-native rows
- **ReportDetailView** — bridge transport badge in grade header
- **ReportAnalyticsView** — bridge filter, overhead comparison chart with delta vs native
- **ReportComparisonView** — bridge transport in headers, highlights when bridges differ
- **ConductorDashboardView** — bridge tag on queue items and completed results

### Migration

- Old `ReportEntity` records get `bridgeTransport = "native"` (column default)
- Old `rawJSON` decodes `bridgeTransport` to `nil` — all queries use `?? "native"` fallback
- Old `orchestrateTest` messages lack `bridgeTransport` — parameter default handles it
- No data loss, no re-processing needed

---

## Design Decisions

1. **Bridge on both sides.** Both controller AND responder use the bridge transport. Matches real-world usage.

2. **Bridge lifecycle.** All four bridge runtimes (FlutterEngine, RCTBridge, CAPBridgeViewController, CordovaBridgeManager) are singletons pre-warmed at app launch and reused across connections. Each transport instance wraps a fresh NativeTransport for the network connection while sharing the bridge runtime.

3. **Single app build.** All bridge transports ship in one build.

4. **Agents must be pre-installed.** All iPads need the same build. `agentCapabilities` handles version mismatches.

5. **Warm-up per bridge run.** Each `runFullSuite()` call includes its own warm-up.

---

## React Native: Separate Build Project

React Native cannot share a CocoaPods workspace with Capacitor due to a fundamental `use_frameworks!` incompatibility:

- **Capacitor** requires `use_frameworks!` (Swift pod with custom module maps)
- **React Native** 0.79+'s C++ internals (Folly, Yoga, cxxreact, JSI, Hermes) break under framework imports — platform-specific headers use header maps incompatible with framework search paths

**Solution:** Build React Native in a completely separate Xcode project (`Bridges/rn_bridge/ios/RNBridge.xcodeproj`), merge all static libraries into `libReactNative.a`, and embed alongside `hermes.xcframework`.

The separate project's Podfile also patches Folly's `Demangle.cpp` for Xcode 16.3+ compatibility.

```bash
cd Bridges/rn_bridge
npm install
npx react-native bundle \
  --entry-file index.js \
  --platform ios \
  --dev false \
  --bundle-output ../../iPadDx/Resources/main.jsbundle
cd ios
pod install
xcodebuild -workspace RNBridge.xcworkspace -scheme RNBridge -sdk iphoneos -configuration Release
# Merge static libs → libReactNative.a, copy hermes.xcframework
```

---

## Known Limitations

### ReactNativeTransport: Classic Bridge Only

Measures the legacy bridge (MessageQueue/BatchedBridge/JSON serialization) architecture. Does not model the newer JSI/TurboModules architecture, which bypasses JSON serialization with direct C++ JSI bindings.

### No "Bridge One Side Only" Toggle

Both sides always use the same bridge transport. A toggle to bridge only one side (for isolating sender vs receiver overhead) was not implemented.

### Standalone Progress UI

Runs bridges sequentially but doesn't show which bridge run is active (e.g., "Run 1/2 — Native").

---

## Files

| File | Role |
|---|---|
| `Networking/TransportProvider.swift` | Protocol + BridgeRegistry + TransportState |
| `Networking/NativeTransport.swift` | Direct NWConnection (baseline) |
| `Networking/CordovaTransport.swift` | Real WKWebView + cordova.js + CDVPlugin |
| `Networking/ReactNativeTransport.swift` | Real RCTBridge + Hermes + ObjC native module |
| `Networking/FlutterTransport.swift` | Real FlutterEngine + FlutterMethodChannel + Dart |
| `Networking/CapacitorTransport.swift` | Real CAPBridgeViewController + CAPPlugin |
| `Networking/BridgeEchoModule.m` | ObjC React Native native module (RCT_EXPORT_MODULE) |
| `Networking/ConnectionManager.swift` | Delegates to TransportProvider |
| `iPadDx-Bridging-Header.h` | ObjC→Swift bridging header for React Native types |
| `Bridges/flutter_bridge/` | Flutter module (Dart echo handler) |
| `Bridges/rn_bridge/` | React Native mini app (JS + separate build project) |
| `Bridges/cordova_bridge/www/` | Cordova web assets (index.html + cordova.js) |
| `Bridges/capacitor_bridge/www/` | Capacitor web assets (index.html) |
| `Models/TestReport.swift` | `bridgeTransport: String?` field |
| `Models/TestSuiteConfig.swift` | `bridgeTransports: [String]` field |
| `Models/ReportEntity.swift` | `bridgeTransport` column |
| `Models/ReportSummary.swift` | `BridgeComparisonRow` struct |
| `Services/ReportStore.swift` | Query methods, export formats, bridge columns |
| `Services/ConductorService.swift` | TestRun queue, bridge-aware execution |
| `Services/AgentService.swift` | Creates ConnectionManager with bridge |
| `Services/AnalyticsReportRenderer.swift` | PDF bridge overhead section |
| `Views/TestSuiteView.swift` | Bridge toggle UI, multi-bridge execution loop |
| `Views/ConductorDashboardView.swift` | Bridge toggle UI, queue display |
