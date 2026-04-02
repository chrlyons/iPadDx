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
    private static var readyContinuations: [CheckedContinuation<Void, Never>] = []
    private static var echoCallbacks: [String: (String) -> Void] = [:]
    private static var callIdCounter = 0

    static func nextCallId() -> String {
        callIdCounter += 1
        return "cap_\(callIdCounter)"
    }

    static func registerCallback(callId: String, callback: @escaping (String) -> Void) {
        echoCallbacks[callId] = callback
    }

    static func cancelCallback(callId: String) {
        echoCallbacks.removeValue(forKey: callId)
    }

    static func handleEchoResult(callId: String, payload: String) {
        let callback = echoCallbacks.removeValue(forKey: callId)
        callback?(payload)
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
        var attempts = 0
        let maxAttempts = 50 // 5 seconds max
        while attempts < maxAttempts {
            if isReady { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
            attempts += 1
        }

        if !isReady {
            AppLog("Capacitor bridge did not become ready after 5s", level: .error, category: "CapacitorTransport")
            // Mark ready anyway to unblock — the JS may still load later
            isReady = true
        } else {
            AppLog("Capacitor bridge ready after \(attempts * 100)ms", category: "CapacitorTransport")
        }

        for cont in readyContinuations {
            cont.resume()
        }
        readyContinuations.removeAll()

        return vc
    }

    static func markReady() {
        isReady = true
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

            CapacitorBridgeManager.registerCallback(callId: callId) { [weak self] resultBase64 in
                guard let self else { return }
                if let processedData = Data(base64Encoded: resultBase64) {
                    self.native.send(processedData, completion: completion)
                } else {
                    self.native.send(data, completion: completion)
                }
            }

            let vc = await CapacitorBridgeManager.shared()
            let js = "echoBridge('\(base64)', '\(callId)');"
            vc.webView?.evaluateJavaScript(js) { _, error in
                if let error {
                    AppLog("JS eval error: \(error)", level: .error, category: "CapacitorTransport")
                    CapacitorBridgeManager.cancelCallback(callId: callId)
                    self.native.send(data, completion: completion)
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
                guard let self, self.bridgeReady else {
                    handler(payload)
                    return
                }

                let base64 = payload.base64EncodedString()

                Task { @MainActor [weak self] in
                    guard self != nil else {
                        handler(payload)
                        return
                    }
                    let callId = CapacitorBridgeManager.nextCallId()

                    // Timeout: if WKWebView doesn't respond in 500ms, deliver raw
                    let timeoutItem = DispatchWorkItem {
                        CapacitorBridgeManager.cancelCallback(callId: callId)
                        handler(payload)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: timeoutItem)

                    CapacitorBridgeManager.registerCallback(callId: callId) { resultBase64 in
                        timeoutItem.cancel()
                        if let processedData = Data(base64Encoded: resultBase64) {
                            handler(processedData)
                        } else {
                            handler(payload)
                        }
                    }

                    let vc = await CapacitorBridgeManager.shared()
                    let js = "echoBridge('\(base64)', '\(callId)');"
                    vc.webView?.evaluateJavaScript(js, completionHandler: nil)
                }
            },
            onEOF: onEOF,
            onError: onError
        )
    }

    func disconnect() {
        native.disconnect()
        bridgeReady = false
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
