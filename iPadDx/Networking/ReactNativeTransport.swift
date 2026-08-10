import Foundation
import Network

/// ObjC-visible class that BridgeEchoModule.m calls to notify Swift.
@objc(ReactNativeBridgeNotifier)
class ReactNativeBridgeNotifier: NSObject {
    @objc static func handleEchoResult(callId: String, payload: String) {
        Task { @MainActor in
            ReactNativeBridgeManager.handleEchoResult(callId: callId, payload: payload)
        }
    }

    @objc static func markReady() {
        Task { @MainActor in
            ReactNativeBridgeManager.markReady()
        }
    }
}

/// Manages a shared RCTBridge instance (real React Native runtime with Hermes)
/// across all ReactNativeTransport connections. Built separately from the main
/// project and linked as a static library to avoid CocoaPods use_frameworks! conflicts.
///
/// Data path: JS NativeModules.BridgeEchoModule.echo(payload, callId)
///   → JSON serialize → MessageQueue batch → RCTBatchedBridge
///   → ObjC BridgeEchoModule.echo() → resolve(payload) → JS callback
@MainActor
enum ReactNativeBridgeManager {
    #if !targetEnvironment(simulator)
        private static var bridge: RCTBridge?
    #endif
    private static var isReady = false
    static var isHealthy = false
    private static var readyContinuations: [CheckedContinuation<Void, Never>] = []
    private static var registry = BridgeCallbackRegistry(prefix: "rn")

    static func nextCallId() -> String {
        registry.nextCallId()
    }

    static func registerCallback(callId: String, callback: @escaping (String) -> Void) {
        registry.register(
            callId: callId,
            callback: callback
        )
    }

    static func cancelCallback(callId: String) {
        registry.cancel(callId: callId)
    }

    static func handleEchoResult(callId: String, payload: String) {
        registry.handle(callId: callId, payload: payload)
    }

    #if !targetEnvironment(simulator)
        static func shared() async -> RCTBridge {
            if let b = bridge, isReady {
                return b
            }

            if let b = bridge {
                await withCheckedContinuation { cont in
                    readyContinuations.append(cont)
                }
                return b
            }

            AppLog("Starting React Native bridge...", category: "RNTransport")

            let b = RCTBridge(delegate: RNBridgeDelegate.shared, launchOptions: nil)!
            bridge = b

            if let attempt = await waitForBridgeReady(isReady: { isReady }, maxAttempts: 80) {
                AppLog("React Native bridge ready after \(attempt * 100)ms", category: "RNTransport")
                isHealthy = true
            } else {
                AppLog("React Native bridge did not become ready after 8s", level: .error, category: "RNTransport")
                // Mark init completed so subsequent shared() callers take the fast path
                // and don't deadlock on an un-resumable continuation.
                isReady = true
                isHealthy = false
            }

            for cont in readyContinuations {
                cont.resume()
            }
            readyContinuations.removeAll()

            return b
        }
    #endif

    static func markReady() {
        AppLog("BridgeEchoModule ready signal received", category: "RNTransport")
        isReady = true
        isHealthy = true
    }
}

// MARK: - RCTBridgeDelegate

#if !targetEnvironment(simulator)
    /// Provides the pre-bundled JS bundle URL to the RCTBridge.
    class RNBridgeDelegate: NSObject, RCTBridgeDelegate {
        static let shared = RNBridgeDelegate()

        func sourceURL(for _: RCTBridge) -> URL? {
            Bundle.main.url(forResource: "main", withExtension: "jsbundle")
        }
    }
#endif

// MARK: - ReactNativeTransport

/// React Native bridge transport — routes data through a REAL RCTBridge
/// running the Hermes JS engine, through REAL RCT_EXPORT_MODULE native module
/// infrastructure, exercising the full MessageQueue/BatchedBridge pipeline.
///
/// Every byte passes through: JS NativeModules.BridgeEchoModule.echo()
/// → JSON serialize → MessageQueue batch → RCTBatchedBridge dispatch
/// → ObjC BridgeEchoModule.echo() → resolve() → JSON serialize
/// → JS Promise callback — the full React Native pipeline.
final class ReactNativeTransport: TransportProvider {
    let bridgeID = "reactnative"
    let bridgeLabel = "React Native Bridge"

    var onStateChange: ((TransportState) -> Void)?

    private let native = NativeTransport()
    private var bridgeReady = false
    private var pendingCallIds: Set<String> = []

    var currentPath: NWPath? {
        native.currentPath
    }

    func connect(to endpoint: NWEndpoint, queue: DispatchQueue) {
        native.onStateChange = { [weak self] state in
            self?.onStateChange?(state)
        }
        native.connect(to: endpoint, queue: queue)
        ensureBridge()
    }

    func accept(_ connection: NWConnection, queue: DispatchQueue) {
        native.onStateChange = { [weak self] state in
            self?.onStateChange?(state)
        }
        native.accept(connection, queue: queue)
        ensureBridge()
    }

    func send(_ data: Data, completion: @escaping (NWError?) -> Void) {
        #if targetEnvironment(simulator)
            // RN bridge not available on simulator — pass through to native
            native.send(data, completion: completion)
        #else
            guard bridgeReady else {
                AppLog("Bridge not ready, sending raw", level: .warning, category: "RNTransport")
                native.send(data, completion: completion)
                return
            }

            let base64 = data.base64EncodedString()

            Task { @MainActor [weak self] in
                guard let self else { return }
                let callId = ReactNativeBridgeManager.nextCallId()
                pendingCallIds.insert(callId)

                ReactNativeBridgeManager.registerCallback(callId: callId) { [weak self] resultBase64 in
                    self?.pendingCallIds.remove(callId)
                    guard let self else { return }
                    if let processedData = Data(base64Encoded: resultBase64) {
                        native.send(processedData, completion: completion)
                    } else {
                        native.send(data, completion: completion)
                    }
                }

                let bridge = await ReactNativeBridgeManager.shared()
                bridge.enqueueJSCall("BridgeEchoModule", method: "echo", args: [base64, callId], completion: nil)
            }
        #endif
    }

    func startReceiving(
        handler: @escaping (Data) -> Void,
        onEOF: @escaping () -> Void,
        onError: @escaping (NWError) -> Void
    ) {
        #if targetEnvironment(simulator)
            native.startReceiving(handler: handler, onEOF: onEOF, onError: onError)
        #else
            native.startReceiving(
                handler: { [weak self] payload in
                    guard let self, bridgeReady else {
                        handler(payload)
                        return
                    }

                    let base64 = payload.base64EncodedString()

                    Task { @MainActor [weak self] in
                        guard let self else {
                            handler(payload)
                            return
                        }
                        let callId = ReactNativeBridgeManager.nextCallId()
                        pendingCallIds.insert(callId)

                        let timeoutItem = DispatchWorkItem { [weak self] in
                            ReactNativeBridgeManager.cancelCallback(callId: callId)
                            self?.pendingCallIds.remove(callId)
                            handler(payload)
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: timeoutItem)

                        ReactNativeBridgeManager.registerCallback(callId: callId) { [weak self] resultBase64 in
                            timeoutItem.cancel()
                            self?.pendingCallIds.remove(callId)
                            if let processedData = Data(base64Encoded: resultBase64) {
                                handler(processedData)
                            } else {
                                handler(payload)
                            }
                        }

                        let bridge = await ReactNativeBridgeManager.shared()
                        bridge.enqueueJSCall(
                            "BridgeEchoModule",
                            method: "echo",
                            args: [base64, callId],
                            completion: nil
                        )
                    }
                },
                onEOF: onEOF,
                onError: onError
            )
        #endif
    }

    func disconnect() {
        native.disconnect()
        bridgeReady = false
        let ids = pendingCallIds
        pendingCallIds.removeAll()
        Task { @MainActor in
            ids.forEach { ReactNativeBridgeManager.cancelCallback(callId: $0) }
        }
    }

    private func ensureBridge() {
        guard !bridgeReady else { return }
        #if !targetEnvironment(simulator)
            Task { @MainActor in
                _ = await ReactNativeBridgeManager.shared()
                self.bridgeReady = true
                AppLog("Bridge connected", category: "RNTransport")
            }
        #endif
    }
}
