# Real Bridge Transport Implementations

## Problem

The current bridge transports (Cordova, Flutter, React Native, Capacitor) are **simulations**, not real implementations. They approximate overhead patterns but don't run actual framework runtimes. This produces misleading data — if the goal is to diagnose real-world connection behavior across frameworks, the measurements must come from real framework code paths.

### Current Status

| Transport | Status | Implementation |
|---|---|---|
| **NativeTransport** | **Real** | Direct Network.framework — baseline |
| **FlutterTransport** | **Real** | FlutterEngine + FlutterMethodChannel + AOT Dart isolate |
| **CapacitorTransport** | **Real** | CAPBridgeViewController + CAPPlugin + WKWebView IPC |
| **CordovaTransport** | **Real** | WKWebView + real cordova.js + CDVPlugin + CDVPluginResult + CDVInvokedUrlCommand |
| **ReactNativeTransport** | **Simulated** | JSContext with MessageQueue structure — no RCTBridge, no Hermes/JSC, no NativeModules |

---

## Plan: Replace Each With Real Embedded Frameworks

The approach for each framework is to embed the real runtime as a lightweight "mini bridge app" inside iPadDx. Each mini app does one thing: receive data from Swift, pass it through the framework's real bridge, and return it. This lets us measure actual bridge overhead on real devices.

---

### 1. Flutter (FlutterEngine — Add-to-App)

**Officially supported.** Flutter's "add-to-app" is a first-class feature.

#### Architecture
```
Swift (iPadDx)
  └─ FlutterEngine (pre-warmed at launch)
       └─ FlutterMethodChannel("com.ipadconn/bridge")
            ├─ Swift → Dart: channel.invokeMethod("send", data)
            └─ Dart → Swift: MethodChannel handler echoes data back
```

#### What Gets Measured
- StandardMethodCodec binary serialization (both directions)
- Dart VM thread scheduling
- In-process UI thread ↔ platform thread dispatch

#### Build Requirements
- Flutter SDK on build machine
- Flutter module (Dart code) as a subproject
- CocoaPods integration (`Flutter.xcframework` + `App.xcframework`)
- Adds ~10-15 MB to binary size

#### Implementation Steps
1. Create a Flutter module: `flutter create --template=module flutter_bridge`
2. Dart side: single MethodChannel handler that echoes `Uint8List` data back
3. Swift side: create `FlutterEngine`, pre-warm at app launch
4. `FlutterTransport` creates a `FlutterMethodChannel` on the engine's binary messenger
5. `send()` calls `channel.invokeMethod("send", flutterData)` and waits for response
6. `startReceiving()` registers a method call handler for incoming data

#### Dart Code (entire mini app)
```dart
import 'dart:typed_data';
import 'package:flutter/services.dart';

void main() {
  final channel = MethodChannel('com.ipadconn/bridge');
  channel.setMethodCallHandler((call) async {
    if (call.method == 'send') {
      // Echo back — the overhead IS the measurement
      return call.arguments;
    }
    return null;
  });
}
```

#### Gotchas
- FlutterEngine cold start is ~200-500ms — must pre-warm
- Engine stays resident in memory (~30-50 MB)
- Xcode build must invoke Flutter's build toolchain (adds CI complexity)
- `BinaryCodec` can bypass serialization if we want to isolate thread-hop overhead separately

---

### 2. React Native (RCTBridge — Integration with Existing Apps)

**Partially supported.** Documented but rougher than Flutter's story.

#### Architecture — Classic Bridge
```
Swift (iPadDx)
  └─ RCTBridge (Hermes JS engine)
       └─ NativeModule: BridgeModule
            ├─ Swift → JS: emit event with data
            └─ JS → Swift: NativeModules.BridgeModule.send(data) → Promise
```

#### Architecture — New Architecture (JSI)
```
Swift (iPadDx)
  └─ RCTHost (new arch entry point)
       └─ TurboModule: BridgeTurboModule
            ├─ Synchronous C++ calls via JSI (no serialization)
            └─ Measures the real JSI overhead path
```

#### What Gets Measured
- **Classic bridge**: JSON serialization, MessageQueue batching (~5ms intervals), async dispatch
- **JSI/TurboModules**: Direct C++ host object access, no serialization, synchronous calls

#### Build Requirements
- Node.js + npm/yarn
- Metro bundler for JS bundle
- CocoaPods (30-50+ pods for React Native)
- Hermes engine (default, AOT bytecode)
- Adds ~8-15 MB to binary size
- **ObjC bridging header required** — NativeModule macros are ObjC (`RCT_EXPORT_MODULE`, `RCT_EXPORT_METHOD`)

#### Implementation Steps
1. Create a minimal RN project alongside iPadDx
2. JS side: single NativeModule call that echoes data
3. Native side: `RCTBridge` initialized with the bundled JS
4. Implement `BridgeModule` as an `RCTBridgeModule` (ObjC, bridged to Swift)
5. `ReactNativeTransport` sends data through the NativeModule and receives via callback/promise
6. Optionally implement a TurboModule variant for JSI measurement

#### JS Code (entire mini app)
```javascript
import { NativeModules, NativeEventEmitter } from 'react-native';
const { BridgeModule } = NativeModules;
const emitter = new NativeEventEmitter(BridgeModule);

// Echo incoming data back through the bridge
emitter.addListener('bridgeData', (data) => {
  BridgeModule.echo(data);
});
```

#### Gotchas
- RCTBridge startup is ~300-800ms — must pre-warm
- Massive dependency tree (React, Yoga, Hermes, cxxreact, jsi, etc.)
- NativeModule ObjC macros create friction in a Swift-first project
- Classic bridge batches calls at ~5ms intervals — latency floor
- New architecture (JSI) is dramatically faster but embedding docs lag behind
- Consider whether both classic and JSI paths are worth measuring (they are very different)

---

### 3. Cordova (WKWebView + CDVPlugin)

**Not officially an "embed" feature**, but the core is just WKWebView + a JS bridge. Entirely feasible.

#### Architecture
```
Swift (iPadDx)
  └─ WKWebView (loaded with cordova.js + mini plugin page)
       └─ WKScriptMessageHandler receives cordova.exec() calls
       └─ CDVPlugin subclass: BridgePlugin
            ├─ JS → Native: cordova.exec(success, error, 'BridgePlugin', 'send', [data])
            └─ Native → JS: commandDelegate.send(CDVPluginResult, callbackId)
```

#### What Gets Measured
- JSON serialization (both directions — this is mandatory in Cordova)
- WKWebView cross-process IPC (WebContent process ↔ App process)
- Base64 encoding for binary data (no ArrayBuffer transfer in Cordova)
- Main thread evaluateJavaScript bottleneck

#### Build Requirements
- CocoaPods: `pod 'Cordova'` (or vendor the source directly)
- No SPM package available
- Bundle `cordova.js` + `config.xml` + minimal HTML
- Adds ~1-2 MB to binary size

#### Implementation Steps
1. Add Cordova iOS via CocoaPods
2. Create a minimal `CDVPlugin` subclass (`BridgePlugin`) that echoes data
3. Create a minimal HTML page that loads `cordova.js` and calls `cordova.exec()`
4. Subclass or configure `CDVViewController` to run inside iPadDx
5. `CordovaTransport.send()` passes data to the webview via `evaluateJavaScript`
6. `BridgePlugin` receives it, returns via `CDVPluginResult`
7. JS success callback posts the result back via `webkit.messageHandlers`

#### Gotchas
- Cordova assumes it owns the app lifecycle — need to manage `pause`/`resume` events manually
- `CDVViewController` reads `config.xml` at startup — must provide a valid one
- WKWebView runs in a separate process — cannot share memory
- Binary data MUST be Base64-encoded (significant overhead for large payloads)
- Cordova is low-maintenance/near-EOL — dependencies may be stale

---

### 4. Capacitor (WKWebView + CAPPlugin)

**Not officially an "embed" feature**, but cleaner architecture than Cordova. SPM support available.

#### Architecture
```
Swift (iPadDx)
  └─ WKWebView (via CAPBridgeViewController)
       └─ WKScriptMessageHandler receives Capacitor.toNative() calls
       └─ CAPPlugin subclass: BridgePlugin
            ├─ JS → Native: Capacitor.toNative('BridgePlugin', 'send', {data})
            └─ Native → JS: call.resolve({data}) via evaluateJavaScript
```

#### What Gets Measured
- JSON serialization (both directions)
- WKWebView cross-process IPC (same as Cordova — WebContent process ↔ App process)
- Base64 encoding for binary data
- Capacitor's `capacitor://localhost` scheme resolution

#### Build Requirements
- SPM: `Capacitor` and `CapacitorCordova` packages (preferred)
- OR CocoaPods: `pod 'Capacitor'`
- Bundle web assets (HTML/JS/CSS)
- Node.js for Capacitor CLI / web asset build
- Adds ~1-2 MB to binary size

#### Implementation Steps
1. Add Capacitor via SPM
2. Create a `CAPPlugin` subclass (`BridgePlugin`) in Swift — native Swift plugin support
3. Create a minimal web page that calls `Capacitor.toNative()`
4. Configure `CAPBridgeViewController` as a child view controller
5. `CapacitorTransport.send()` passes data to the bridge plugin
6. Plugin echoes data back through `call.resolve()`
7. JS callback triggers `webkit.messageHandlers` back to native

#### Gotchas
- Capacitor assumes it owns navigation and web server config
- Plugin registration uses a generated manifest — embedding requires manual registration
- Same WKWebView process boundary and Base64 limitations as Cordova
- The `capacitor://localhost` scheme requires proper URL scheme handling

---

## Comparison: Real Overhead Characteristics

| Framework | Process Boundary | Serialization | Binary Data | Dominant Overhead |
|---|---|---|---|---|
| **Native** | None | None | Raw bytes | Baseline |
| **Flutter** | None (in-process) | Binary codec (or raw via BinaryCodec) | Uint8List (zero-copy) | Thread dispatch |
| **React Native (JSI)** | None (in-process) | None (direct C++ access) | ArrayBuffer | Minimal |
| **React Native (classic)** | None (in-process) | JSON + batching | Base64 | Batch interval (~5ms) |
| **Cordova** | Yes (WKWebView) | JSON | Base64 only | IPC + JSON + Base64 |
| **Capacitor** | Yes (WKWebView) | JSON | Base64 only | IPC + JSON + Base64 |

---

## Recommended Implementation Order

1. **Flutter** — cleanest embed story, officially supported, well-documented. Start here to validate the approach.
2. **Capacitor** — already partially real (WKWebView IPC is genuine). SPM support makes integration cleaner. Smallest delta from current state.
3. **Cordova** — similar to Capacitor but with CocoaPods dependency and more lifecycle friction.
4. **React Native** — largest dependency footprint and most complex integration. Save for last. Consider whether both classic bridge and JSI are needed.

---

## Project Structure

```
iPadDx/
├── Networking/
│   ├── NativeTransport.swift          (unchanged — real baseline)
│   ├── FlutterTransport.swift         (rewrite — wraps real FlutterEngine)
│   ├── ReactNativeTransport.swift     (rewrite — wraps real RCTBridge)
│   ├── CordovaTransport.swift         (rewrite — wraps real CDVViewController)
│   └── CapacitorTransport.swift       (rewrite — wraps real CAPBridgeViewController)
├── Bridges/
│   ├── flutter_bridge/                (Flutter module — Dart code)
│   ├── rn_bridge/                     (React Native mini app — JS code)
│   ├── cordova_bridge/                (Cordova web assets — HTML/JS + config.xml)
│   └── capacitor_bridge/             (Capacitor web assets — HTML/JS)
```

---

## Open Questions

1. **Binary size budget** — Flutter + React Native add ~20-30 MB combined. Is this acceptable for a diagnostic tool?
2. **CI/CD complexity** — Flutter SDK and Node.js must be available in the build pipeline. How does this affect the current Xcode-only build?
3. **Startup time** — FlutterEngine and RCTBridge each take hundreds of ms to warm up. Should we pre-warm all engines at app launch, or lazily initialize when a bridge transport is selected?
4. **React Native: classic vs JSI** — These have fundamentally different overhead profiles. Should we ship both as separate transports ("reactnative-classic" and "reactnative-jsi")?
5. **Scope** — Do we need all four bridges, or should we prioritize the ones Assess actually uses? If Assess 2.0 is Cordova-based, Cordova is the critical one.
