# Bridge Overhead Testing

## Problem Statement

iPadDx tests device-to-device connections using native Swift on Network.framework. Real-world apps  go through a bridge layer (Cordova, React Native, Flutter, etc.) that adds overhead to every message. iPadDx can route the same traffic through real bridge runtimes — but only in one configuration, described immediately below.

---

## Scope: Where Bridging Actually Happens

**A bridge measurement only means something when the runtime is active on both ends of the connection.** Only one of the three ways a suite can run satisfies that, so only one produces a real bridge comparison.

| Configuration | Transport used | Bridge comparison? |
|---|---|---|
| Standalone (two devices paired directly, `TestSuiteView`) | Always native | No — the UI no longer offers bridge selection |
| Conductor self-run (conductor is one endpoint) | Always native | No — a non-native run is refused, not run |
| Conductor agent-to-agent (two agents, conductor orchestrates) | The selected bridge, on both agents | **Yes — this is the only real comparison** |

Why:

- **Standalone.** The connection is created when the two devices pair, long before any bridge could be chosen, and it is native on both sides. Re-labelling that run as "cordova" would be a lie, and there is no way to re-bridge an already-established peer from one side. `TestSuiteView` therefore states plainly that "Standalone tests always run over the native transport" and points the user at Conductor mode.
- **Conductor self-run.** The conductor's fleet connection to an agent is likewise native from the moment the agent joins the fleet. `ConductorService.executeSelfRun` refuses any run whose `bridgeTransport` is not `native`, logs *"the conductor itself cannot be bridged — run bridge comparisons between two agents"*, and records the run as a failure rather than emitting a mislabelled report.
- **Conductor agent-to-agent.** `ConductorService.executeRemoteRun` sends `orchestrateTest(..., bridgeTransport:)` to both agents. Each agent then builds a *fresh* `ConnectionManager(bridgeTransport:)` for the partner link — the responder in `handlePartnerConnection`, the controller in `executeTest` — so the runtime really is loaded on both sides for the whole suite.

There is no `bridgeTransportOverride` any more. A report's `bridgeTransport` is written straight from `connectionManager.bridgeTransport` when `TestSuiteRunner` builds the `TestReport`, so the label on a report is always the transport that actually carried the bytes.

---

## Bridge Types

All five bridges ship in a single build, all running **real framework runtimes** (no simulations). Selection happens in Conductor mode only (see [Scope](#scope-where-bridging-actually-happens)).

| Bridge ID | Technology | Target App Example |
|-----------|-----------|-------------------|
| `native` | Direct Swift / Network.framework | iPadDx itself (baseline) |
| `cordova` | WKWebView + real cordova.js + CDVPlugin + CDVPluginResult | — |
| `reactnative` | RCTBridge + Hermes engine + ObjC RCT_EXPORT_MODULE | — |
| `flutter` | FlutterEngine + FlutterMethodChannel + AOT Dart isolate | — |
| `capacitor` | CAPBridgeViewController + CAPPlugin + WKWebView IPC | — |

The `native` bridge is always available and cannot be deselected (it's the baseline for comparison).

Every bridge runtime records whether its JS/Dart side actually signalled readiness (`BridgeRegistry.isBridgeHealthy`). A runtime that timed out during init is reported as unhealthy, and both `ConductorService.executeSelfRun` and `AgentService.executeTest` refuse to run over it rather than produce a report labelled with a bridge that never initialised.

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

The three round-trip bridges (Cordova, Capacitor, React Native) share the helpers in
`BridgeShared.swift`: a call-id registry (`BridgeCallbackRegistry`) pairs each outbound frame with
the callback that completes it, and a readiness poll (`waitForBridgeReady`) waits for the runtime's
own ready signal. Flutter needs neither — `FlutterMethodChannel.invokeMethod` carries its own reply
callback, and readiness is a `ping`/`pong` round trip over the channel.

All four bridge in **both directions**. `send()` pushes the frame through the runtime and only
hands the returned bytes to `NativeTransport` afterwards; `startReceiving()` takes the frame off
the wire and pushes it through the runtime *before* delivering it to `ConnectionManager`. So on a
run where both agents are bridged, every frame crosses the runtime twice per hop.

In the receive direction the three round-trip bridges arm a 500 ms watchdog (`DispatchWorkItem` in
`startReceiving`): if the runtime has not answered by then, the raw frame is delivered unbridged and
that frame's overhead is silently missing from the measurement. Flutter has no such watchdog — it
waits for the channel reply.

### Cordova (WKWebView + CDVPlugin)

- Real WKWebView running real `cordova.js` (from CapacitorCordova)
- Real `CDVPlugin` subclass (`CordovaEchoPlugin`) with `CDVPluginResult` + `CDVInvokedUrlCommand`
- Real `CDVCommandDelegate` implementation delivering results via `evaluateJavaScript(nativeCallback)`
- `WKScriptMessageHandler` receives `cordova.exec()` calls from JS

```
Send: Swift → base64 → WKWebView evaluateJavaScript("echoBridge(b64, callId)") → [WebKit IPC]
  → cordova.exec('BridgePlugin','echo') → webkit.messageHandlers.bridge.postMessage() → [WebKit IPC]
  → CordovaBridgeMessageHandler → CDVInvokedUrlCommand → CordovaEchoPlugin.echo()
  → CordovaBridgeManager.handleEchoResult(callId:) → Swift callback → base64 decode → NWConnection
```

**Which leg completes the round trip.** `CordovaEchoPlugin.echo()` does two things: it sends a real
`CDVPluginResult` back through `CordovaBridgeCommandDelegate.send()`, which runs the genuine
`cordova.require('cordova/exec').nativeCallback(...)` JS call over WebKit IPC — and it separately
calls `CordovaBridgeManager.handleEchoResult(callId:payload:)` in Swift. It is the **second**, native
call that resumes the transport and releases the bytes to the socket. The JS success callback in
`cordova_bridge/www/index.html` is deliberately empty (`/* native handles result via
handleEchoResult */`). The nativeCallback leg is still executed and still costs what it costs, but
the doc previously claimed the JS callback was what returned the data to Swift; it is not.

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

As with Cordova, `resolve(payload)` fulfils a JS promise that nothing awaits; the leg that actually
completes the round trip is `[ReactNativeBridgeNotifier handleEchoResultWithCallId:payload:]`, called
from `BridgeEchoModule.m` immediately after `resolve`.

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
Send: Swift → base64 → webView.evaluateJavaScript("echoBridge(b64, callId)") → [WebKit IPC]
  → JS Capacitor.toNative('BridgeEchoPlugin','echo', {payload, callId}) → [WebKit IPC]
  → CapacitorBridge → BridgeEchoPlugin.echo(CAPPluginCall)
  → CapacitorBridgeManager.handleEchoResult(callId:) → Swift callback → base64 decode → NWConnection
```

**Which leg completes the round trip.** Same shape as Cordova. `BridgeEchoPlugin.echo` calls
`call.resolve(["payload": payload])`, which runs Capacitor's real `fromNative` callback back into
JS — and then calls `CapacitorBridgeManager.handleEchoResult(callId:payload:)`. The transport is
resumed by that native call, not by the JS promise; `capacitor_bridge/www/index.html` fires
`Capacitor.toNative(...)` and ignores the result entirely.

---

## What Actually Crosses the Bridge

This matters for what a comparison measures, because the traffic changed.

`DiagnosticMessage.throughputData` now carries `payload: Data` — a real 32 KB chunk from
`ThroughputPayload.sharedChunk` (a pseudo-random buffer generated once and reused, so the cost is
transfer, not allocation). The sender streams those chunks with per-chunk backpressure via
`ConnectionManager.sendAwaitingCompletion`, and the reported rate comes from the receiver's
`throughputAck(testID:bytesReceived:duration:)` — the bytes the peer counted, over the time the peer
measured. The load phases — Phase 5 (Latency Under Load) and Phase 6 (Heavy Load Stress) — use
`TestSuiteRunner.startLoadGenerator`, which streams the same real chunks for the whole measurement
window under a throwaway test ID, so the load bytes genuinely occupy the link (and the bridge)
without entering any throughput figure.

Consequence for bridge testing: **the payload really crosses the bridge.** Every one of those chunks
is JSON-encoded by `DiagnosticMessage.encode()` (which base64s the `Data` field, a ~4/3 expansion),
then the WKWebView and React Native transports base64 the whole framed message again to hand it to
JS (another ~4/3), and the resulting string crosses the WebKit process boundary twice — per chunk,
per direction, on each bridged hop. Previously the throughput message had no payload, so a bridge
comparison was measuring the framework's cost of shuttling near-empty control frames. It is now
measuring the framework's cost of moving the actual bytes, which is the thing an app developer
cares about.

---

## Test Configuration

### TestSuiteConfig

```swift
struct TestSuiteConfig: Codable {
    // ... phase toggles ...
    var bridgeTransports: [String] = ["native"]
}
```

`bridgeTransports` is vestigial: nothing reads it any more. Standalone mode has no bridge selection,
and conductor runs carry the bridge in the `orchestrateTest` message rather than in the config. The
field is left on the struct so previously encoded configs still decode.

### TestRun Model

Each queue entry is a pair + bridge combination:

```swift
struct TestRun: Identifiable, Equatable {
    let id = UUID()
    let pair: TestPair
    let bridgeTransport: String
    var label: String  // pair.label, plus " [cordova]" when not native
}
```

### Queue Ordering

`ConductorService.generateAllPairs()` first builds every **ordered** pair (both directions, so
`n` devices give `P = n × (n − 1)` pairs), then emits one `TestRun` per pair per selected bridge —
`P × B` runs.

With a single bridge selected the queue is simply the pair list in order. With several, the queue is
built by stepping through the pair list once and, at each step, emitting one run per bridge with
each bridge's index into the pair list **offset** by `bridgeIndex × (P / B)`:

```swift
for step in 0 ..< pairs.count {
    for (bridgeIndex, bridge) in selectedBridges.enumerated() {
        let pairIndex = (step + bridgeIndex * max(1, pairs.count / selectedBridges.count)) % pairs.count
        testQueue.append(TestRun(pair: pairs[pairIndex], bridgeTransport: bridge))
    }
}
```

The offset is the point. The earlier implementation round-robined the bridges at the *same* index,
which produced `pair0 [native]`, `pair0 [cordova]`, … — running one pair back to back under two
bridges, exactly the adjacency the interleave exists to avoid, and letting thermal state from the
first run contaminate the second.

Three devices (A, B, C) → 6 ordered pairs `[A→B, A→C, B→A, B→C, C→A, C→B]`; two bridges
(`native`, `cordova`) → offset stride 3. The queue comes out as:

```
A→B [native]     ← step 0
B→C [cordova]
A→C [native]     ← step 1
C→A [cordova]
B→A [native]     ← step 2
C→B [cordova]
B→C [native]     ← step 3
A→B [cordova]      (A→B's second bridge, 7 runs after its first)
C→A [native]     ← step 4
A→C [cordova]
C→B [native]     ← step 5
B→A [cordova]
```

No pair appears in two consecutive entries, and a pair's two bridge variants are separated by
roughly the length of the pair list.

---

## UI

### Standalone Mode (TestSuiteView)

**No bridge selection.** Where the toggles used to be there is now a fixed "Bridge Transport —
Native" row explaining that standalone tests always run over the native transport, and directing the
user to Conductor mode for bridge comparison ("a bridge has to be active on both devices, which
requires a fresh orchestrated connection on each").

### Conductor Mode (ConductorDashboardView)

Bridge toggle section (`bridgeTransportSection`). Native is always on and cannot be tapped off.
The section is disabled while `conductor.isQueueRunning`. `generateAllPairs()` creates `P × B`
TestRuns. Queue rows and completed-result rows show the bridge as a tag on non-native runs.

### Bridge Info (BridgeInfoView)

Per-bridge technology, characteristics, data path, and a live `BridgeHealthBadge` per runtime
(Ready / Failed, from `BridgeRegistry.isBridgeHealthy`).

Its "Overhead Comparison" section used to display **hardcoded overhead percentages**. It now renders
only measured data: it picks the device pair with the most bridges on record, pulls
`store.bridgeComparison(local:remote:)`, and draws a bar per bridge with the measured average
latency, plus a percentage against the native row when a native run exists for that pair. If no
reports have been saved it shows an explicit empty state ("No bridge measurements recorded yet")
rather than numbers. It also prints the per-bridge report counts, so it is visible how thin the
sample is.

---

## Execution Flow

### Standalone Mode

```
User taps Start Test Suite
  → one run, over whatever transport this connection actually uses (native)
  → report records that transport verbatim
```

### Conductor Mode

```
Conductor selects bridges → All Pairs → Run Queue
  → Scheduler picks next TestRun where both devices idle
  → Self run (conductor is an endpoint)?
      · bridge unhealthy      → recorded as a failure, no retry
      · bridge != native      → refused and recorded as a failure
                                (the conductor's fleet link is native and cannot be re-bridged)
      · native                → conductor runs the suite itself
  → Agent-to-agent run?
      · validateBridgeSupport(connA, connB, bridge) — both must advertise it,
        otherwise recorded as a failure, no retry
      · orchestrateTest(..., bridgeTransport) to responder, then to controller
      · each agent builds a fresh ConnectionManager(bridgeTransport:) → TransportProvider
      · test runs through the bridge on both sides
  → Report returned to conductor; bridgeTransport is the transport that carried it
  → Timeouts/no-report go through handleRunFailure → bounded auto-retry, then failure
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

All string fields are run through `csvEscape` before being written.

- **Single report** — `Bridge Transport,<value>` line in the header (omitted entirely for old reports where the field is nil)
- **Summary CSV** — "Bridge Transport" column between Remote OS and Grade
- **Analytics CSV** — a "Bridge Transports" line in the overview header; then, **only when more than one bridge is present**, a "Bridge Comparison" section and a bridge dimension added to the per-pair and per-chip breakdowns

  The Bridge Comparison section is `Bridge, Reports, Avg Latency (ms), P95 Latency (ms), Throughput (MB/s), Avg Jitter (ms), Packet Loss (%), Load Degradation (%), Excellent, Good, Fair, Poor` — **absolute per-bridge figures only**. There is no delta-vs-native column in the CSV; earlier revisions of this document claimed one. Deltas are computed in the PDF and in the analytics view, not here.

### PDF Analytics

`AnalyticsReportRenderer` adds a "Bridge Overhead Analysis" section when multiple bridges are present: a per-bridge comparison table whose delta column is the millisecond difference against the native rows' average latency (`—` on the native row itself), plus a per-pair bridge breakdown. The PDF renders with fixed light colours so output does not change with the device's appearance setting.

### View Integration

- **ReportListView** — bridge filter picker (only shown once reports from more than one bridge exist), bridge tag on non-native rows
- **ReportDetailView** — bridge transport badge in the grade header, on non-native reports
- **ReportAnalyticsView** — bridge filter picker, and a "Bridge Overhead" chart (shown only when the store holds more than one bridge, drawn only when at least two bridges survive the current filters) with per-bridge average bars and, when a native row is present, a `+X.X unit (+Y%)` delta line per non-native bridge
- **ReportComparisonView** — bridge transport in headers, highlights when bridges differ
- **ConductorDashboardView** — bridge tag on queue items and completed results
- **BridgeInfoView** — measured overhead comparison, or an empty state (see [UI](#bridge-info-bridgeinfoview))

### Migration

- Old `ReportEntity` records get `bridgeTransport = "native"` (column default)
- Old `rawJSON` decodes `bridgeTransport` to `nil` — all queries use `?? "native"` fallback
- Old `orchestrateTest` messages lack `bridgeTransport` — parameter default handles it
- No data loss, no re-processing needed

---

## Design Decisions

1. **Bridge on both sides, or not at all.** A bridged run only happens where the runtime can be loaded on both ends — conductor-orchestrated agent-to-agent runs, where each agent builds a fresh bridged `ConnectionManager`. Configurations that cannot bridge both ends (standalone, conductor self-runs) are native-only and are labelled native, rather than being run and mislabelled. Losing conductor self-runs from bridge comparison is the deliberate cost of that honesty; a fleet needs two agents besides the conductor to compare bridges.

2. **Bridge lifecycle.** All four bridge runtimes (FlutterEngine, RCTBridge, CAPBridgeViewController, CordovaBridgeManager) are singletons pre-warmed from `iPadDxApp.init()` (React Native excluded on the simulator) and reused across connections. Each transport instance wraps a fresh NativeTransport for the network connection while sharing the bridge runtime.

3. **Single app build.** All bridge transports ship in one build.

4. **Agents must be pre-installed.** All iPads need the same build. `agentCapabilities(supportedBridges:)` reports what each agent has, and `validateBridgeSupport` refuses to dispatch a bridge that both ends have not advertised.

5. **Warm-up per bridge run.** Each `runFullSuite()` call includes its own warm-up.

6. **A refused or unsupported bridge is a failure, not a silent skip.** It lands in `failedRuns` and is visible in the conductor's results, with no retry — bridge health and capability are not transient conditions.

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

### Bridge Comparison Needs Two Agents

The headline limitation, restated: only conductor-orchestrated **agent-to-agent** runs are bridged. Standalone mode is native-only and no longer offers a choice; a conductor self-run with a non-native bridge is refused and recorded as a failure. Comparing bridges therefore requires a conductor plus at least two agents.

### Traffic Before the Bridge Is Ready Falls Back to Native

Each transport's `send()` checks a `bridgeReady` flag that is only set once `ensureBridge()` has awaited the runtime. Anything sent before that — the flag is set asynchronously after `connect()`/`accept()` — goes straight out over `NativeTransport` with a `"Bridge not ready, sending raw"` warning in the log and **nothing else**: the frame is not queued, retried, or counted as skipped, and the report still says the run used that bridge. `startReceiving()` behaves the same way, and additionally falls back to the raw frame whenever the runtime takes longer than 500 ms to answer. Nothing in the connection's readiness check covers the bridge: `waitForReady` reports the *native* socket state, so a connection can be "ready" while `bridgeReady` is still false. The pre-warm at launch makes this unlikely in practice — the runtimes are usually up long before a test starts — but there is no guarantee and no accounting of how many frames took the fallback path.

### The Health Gate Does Not Cover the Responder

`isBridgeHealthy` is checked by the conductor before a self run and by an agent before taking the **controller** role. The **responder** role (`AgentService.handlePartnerConnection`) builds its bridged `ConnectionManager` without that check. And `agentCapabilities(supportedBridges:)` advertises `BridgeRegistry.enabledBridgeIDs` — what the *build* contains, not what initialised successfully on that device — so `validateBridgeSupport` cannot catch it either. A device whose runtime failed to start can therefore still be accepted as a responder, where its sends fall back to raw and its receives take the 500 ms timeout path.

### React Native Is a Native Pass-Through on the Simulator

`ReactNativeTransport` is compiled with `#if targetEnvironment(simulator)` branches that skip the bridge entirely and call `NativeTransport` directly, because the RN static library is device-only. `ReactNativeBridgeManager` is likewise never started there, so `isHealthy` stays false — which means `BridgeRegistry.isBridgeHealthy("reactnative")` returns false and both `ConductorService.executeSelfRun` and `AgentService.executeTest` refuse the run outright rather than measuring the pass-through. Simulator results for React Native therefore do not exist rather than being wrong, but there is no simulator coverage of this bridge at all.

### ReactNativeTransport: Classic Bridge Only

Measures the legacy bridge (MessageQueue/BatchedBridge/JSON serialization) architecture. Does not model the newer JSI/TurboModules architecture, which bypasses JSON serialization with direct C++ JSI bindings.

### No "Bridge One Side Only" Toggle

Within a bridged agent-to-agent run, both sides always use the same bridge transport. A toggle to bridge only one side (for isolating sender vs receiver overhead) was not implemented.

### The Echo Is an Echo, Not an App

Every bridge plugin does the minimum: hand the payload to the runtime and take the same bytes back. That measures the runtime's transport cost (serialization, IPC, thread dispatch) and nothing else. A real app also does work *inside* the runtime, which this cannot capture.

### Base64 Is Counted Twice

`DiagnosticMessage.encode()` already base64s the payload into JSON, and the WebView/RN transports base64 the framed message again. That double expansion is real cost that a bridged run pays and a native run does not — it is part of what "bridge overhead" means here, but it is a property of this harness's framing, not something every bridged app would pay identically.

### `TestSuiteConfig.bridgeTransports` Is Dead

Retained for decoding old configs; no code path reads it.

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
| `Networking/BridgeShared.swift` | `waitForBridgeReady` poll + `BridgeCallbackRegistry` call-id registry shared by Cordova/Capacitor/RN |
| `Networking/ConnectionManager.swift` | Delegates to TransportProvider; `bridgeTransport` is what reports record |
| `iPadDx-Bridging-Header.h` | ObjC→Swift bridging header for React Native types |
| `Bridges/flutter_bridge/` | Flutter module (Dart echo handler) |
| `Bridges/rn_bridge/` | React Native mini app (JS + separate build project) |
| `Bridges/cordova_bridge/www/` | Cordova web assets (index.html + cordova.js) |
| `Bridges/capacitor_bridge/www/` | Capacitor web assets (index.html) |
| `Models/TestReport.swift` | `bridgeTransport: String?` field |
| `Models/DiagnosticMessage.swift` | `ThroughputPayload` 32 KB chunk + `throughputData(payload:)` / `throughputAck` — the real bytes that cross the bridge |
| `Models/TestSuiteConfig.swift` | `bridgeTransports: [String]` field (unused) |
| `Models/ReportEntity.swift` | `bridgeTransport` column |
| `Models/ReportSummary.swift` | `BridgeComparisonRow` struct |
| `Services/ReportStore.swift` | Query methods, export formats, bridge columns |
| `Services/ConductorService.swift` | TestRun queue + interleave, bridge health/capability gates, self-run refusal |
| `Services/AgentService.swift` | Builds the bridged ConnectionManager on both agent roles |
| `Services/TestSuiteRunner.swift` | Streams real payload chunks (throughput + load generator) over whichever transport is in use |
| `Services/AnalyticsReportRenderer.swift` | PDF bridge overhead section |
| `Views/TestSuiteView.swift` | States that standalone runs are native-only |
| `Views/ConductorDashboardView.swift` | Bridge toggle UI, queue display |
| `Views/BridgeInfoView.swift` | Bridge reference, per-runtime health badges, measured-overhead comparison with empty state |
