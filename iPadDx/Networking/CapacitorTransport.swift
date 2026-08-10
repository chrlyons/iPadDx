import Capacitor
import Foundation
import Network
import WebKit

/// Manages a shared Capacitor bridge instance (CAPBridgeViewController) across
/// all CapacitorTransport connections. The bridge is created once and reused.
@MainActor
enum CapacitorBridgeManager {
    private static var viewController: CAPBridgeViewController?
    private static var isReady = false
    static var isHealthy = false
    private static var readyContinuations: [CheckedContinuation<Void, Never>] = []
    private static var registry = BridgeCallbackRegistry(prefix: "cap")

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

    static func shared() async -> CAPBridgeViewController {
        if let vc = viewController, isReady {
            return vc
        }

        if let vc = viewController {
            await withCheckedContinuation { cont in
                readyContinuations.append(cont)
            }
            return vc
        }

        AppLog("Starting Capacitor bridge...", category: "CapacitorTransport")
        let vc = BridgeEchoViewController()
        viewController = vc

        // The view controller needs to be in the view hierarchy for WKWebView to work,
        // but we keep it hidden (zero frame, no window attachment needed — just load the view).
        vc.loadViewIfNeeded()

        // Wait for the web view to load and the JS bridge to signal readiness
        if let attempt = await waitForBridgeReady(isReady: { isReady }) {
            AppLog("Capacitor bridge ready after \(attempt * 100)ms", category: "CapacitorTransport")
            isHealthy = true
        } else {
            AppLog("Capacitor bridge did not become ready after 5s", level: .error, category: "CapacitorTransport")
            // Mark init completed so subsequent shared() callers take the fast path
            // and don't deadlock on an un-resumable continuation. isHealthy=false
            // is the signal callers check via BridgeRegistry.isBridgeHealthy().
            isReady = true
            isHealthy = false
        }

        for cont in readyContinuations {
            cont.resume()
        }
        readyContinuations.removeAll()

        return vc
    }

    static func markReady() {
        isReady = true
        isHealthy = true
    }
}

/// Custom CAPBridgeViewController subclass that loads our minimal bridge test page
/// and registers the BridgeEchoPlugin.
class BridgeEchoViewController: CAPBridgeViewController {
    override func instanceDescriptor() -> InstanceDescriptor {
        let descriptor = InstanceDescriptor()
        // Point to our bundled www directory with index.html
        if let wwwPath = Bundle.main.path(forResource: "capacitor_www", ofType: nil) {
            descriptor.appLocation = URL(fileURLWithPath: wwwPath)
        }
        return descriptor
    }

    override func capacitorDidLoad() {
        // Register our echo plugin with the bridge
        bridge?.registerPluginInstance(BridgeEchoPlugin())
    }
}

/// Real Capacitor plugin that echoes data back through the bridge.
/// This exercises the full CAPPlugin → CAPPluginCall → resolve() path.
@objc(BridgeEchoPlugin)
class BridgeEchoPlugin: CAPInstancePlugin, CAPBridgedPlugin {
    let identifier = "BridgeEchoPlugin"
    let jsName = "BridgeEchoPlugin"
    let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "echo", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "ready", returnType: CAPPluginReturnPromise),
    ]

    @objc func echo(_ call: CAPPluginCall) {
        let payload = call.getString("payload") ?? ""
        let callId = call.getString("callId") ?? ""

        // Return the payload through the real Capacitor plugin result path
        call.resolve(["payload": payload])

        // Also notify the native callback registry
        Task { @MainActor in
            CapacitorBridgeManager.handleEchoResult(callId: callId, payload: payload)
        }
    }

    @objc func ready(_ call: CAPPluginCall) {
        AppLog("BridgeEchoPlugin ready signal received", category: "CapacitorTransport")
        call.resolve()
        Task { @MainActor in
            CapacitorBridgeManager.markReady()
        }
    }
}

/// Capacitor bridge transport — routes data through a REAL CAPBridgeViewController,
/// real Capacitor native-bridge.js, and a real CAPPlugin subclass.
///
/// Every byte passes through: JS Capacitor.toNative() → WKWebView IPC (cross-process) →
/// WKScriptMessageHandler → CapacitorBridge.handleJSCall → BridgeEchoPlugin.echo() →
/// CAPPluginCall.resolve() → evaluateJavaScript callback — the full Capacitor pipeline.
final class CapacitorTransport: TransportProvider {
    let bridgeID = "capacitor"
    let bridgeLabel = "Capacitor Bridge"

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
        guard bridgeReady else {
            AppLog("Bridge not ready, sending raw", level: .warning, category: "CapacitorTransport")
            native.send(data, completion: completion)
            return
        }

        let base64 = data.base64EncodedString()

        Task { @MainActor [weak self] in
            guard let self else { return }
            let callId = CapacitorBridgeManager.nextCallId()
            pendingCallIds.insert(callId)

            CapacitorBridgeManager.registerCallback(callId: callId) { [weak self] resultBase64 in
                self?.pendingCallIds.remove(callId)
                guard let self else { return }
                if let processedData = Data(base64Encoded: resultBase64) {
                    native.send(processedData, completion: completion)
                } else {
                    native.send(data, completion: completion)
                }
            }

            let vc = await CapacitorBridgeManager.shared()
            let js = "echoBridge('\(base64)', '\(callId)');"
            vc.webView?.evaluateJavaScript(js) { [weak self] _, error in
                if let error {
                    AppLog("JS eval error: \(error)", level: .error, category: "CapacitorTransport")
                    CapacitorBridgeManager.cancelCallback(callId: callId)
                    self?.pendingCallIds.remove(callId)
                    self?.native.send(data, completion: completion)
                }
            }
        }
    }

    func startReceiving(
        handler: @escaping (Data) -> Void,
        onEOF: @escaping () -> Void,
        onError: @escaping (NWError) -> Void
    ) {
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
                    let callId = CapacitorBridgeManager.nextCallId()
                    pendingCallIds.insert(callId)

                    // Timeout: if WKWebView doesn't respond in 500ms, deliver raw
                    let timeoutItem = DispatchWorkItem { [weak self] in
                        CapacitorBridgeManager.cancelCallback(callId: callId)
                        self?.pendingCallIds.remove(callId)
                        handler(payload)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: timeoutItem)

                    CapacitorBridgeManager.registerCallback(callId: callId) { [weak self] resultBase64 in
                        timeoutItem.cancel()
                        self?.pendingCallIds.remove(callId)
                        if let processedData = Data(base64Encoded: resultBase64) {
                            handler(processedData)
                        } else {
                            handler(payload)
                        }
                    }

                    let vc = await CapacitorBridgeManager.shared()
                    let js = "echoBridge('\(base64)', '\(callId)');"
                    vc.webView?.evaluateJavaScript(js) { _, error in
                        if let error {
                            AppLog("JS eval error (recv): \(error)", level: .error, category: "CapacitorTransport")
                        }
                    }
                }
            },
            onEOF: onEOF,
            onError: onError
        )
    }

    func disconnect() {
        native.disconnect()
        bridgeReady = false
        let ids = pendingCallIds
        pendingCallIds.removeAll()
        Task { @MainActor in
            ids.forEach { CapacitorBridgeManager.cancelCallback(callId: $0) }
        }
    }

    private func ensureBridge() {
        guard !bridgeReady else { return }
        Task { @MainActor in
            _ = await CapacitorBridgeManager.shared()
            self.bridgeReady = true
            AppLog("Bridge connected", category: "CapacitorTransport")
        }
    }
}
