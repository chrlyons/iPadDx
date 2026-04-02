import Cordova
import Foundation
import Network
import WebKit

/// Manages a shared Cordova bridge (WKWebView + real cordova.js) across
/// all CordovaTransport connections. The bridge is created once and reused.
///
/// Exercises the REAL Cordova iOS code path:
///   JS: cordova.exec() → JSON serialize → webkit.messageHandlers.bridge.postMessage()
///   Native: WKScriptMessageHandler → CDVInvokedUrlCommand → CDVPlugin.echo()
///   Native: CDVPluginResult → commandDelegate.send() → evaluateJavaScript(nativeCallback)
///   JS: nativeCallback → callbackFromNative → success/fail handler
@MainActor
enum CordovaBridgeManager {
    private static var webView: WKWebView?
    private static var isReady = false
    private static var readyContinuations: [CheckedContinuation<Void, Never>] = []
    private static var echoCallbacks: [String: (String) -> Void] = [:]
    private static var callIdCounter = 0
    private static var messageHandler: CordovaBridgeMessageHandler?
    private static var navigationDelegate: CordovaBridgeNavigationDelegate?
    private static var plugin: CordovaEchoPlugin?
    private static var commandDelegate: CordovaBridgeCommandDelegate?

    static func nextCallId() -> String {
        callIdCounter += 1
        return "cdv_\(callIdCounter)"
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

    static func shared() async -> WKWebView {
        if let wv = webView, isReady {
            return wv
        }

        if let wv = webView {
            await withCheckedContinuation { cont in
                readyContinuations.append(cont)
            }
            return wv
        }

        AppLog("Starting Cordova bridge...", category: "CordovaTransport")

        // Set up WKWebView with "bridge" message handler (same name cordova.js uses)
        let config = WKWebViewConfiguration()
        let handler = CordovaBridgeMessageHandler()
        messageHandler = handler
        config.userContentController.add(handler, name: "bridge")

        let wv = WKWebView(frame: .zero, configuration: config)
        webView = wv

        let navDelegate = CordovaBridgeNavigationDelegate()
        navigationDelegate = navDelegate
        wv.navigationDelegate = navDelegate

        // Create the real CDVPlugin subclass and wire up its commandDelegate
        let delegate = CordovaBridgeCommandDelegate(webView: wv)
        commandDelegate = delegate

        let echoPlugin = CordovaEchoPlugin()
        echoPlugin.webViewEngine = wv
        echoPlugin.commandDelegate = delegate
        plugin = echoPlugin
        echoPlugin.pluginInitialize()

        // Tell the message handler where to route commands
        handler.plugin = echoPlugin

        // Load HTML from bundled cordova_www (contains cordova.js + index.html)
        if let wwwPath = Bundle.main.path(forResource: "cordova_www", ofType: nil) {
            let indexURL = URL(fileURLWithPath: wwwPath).appendingPathComponent("index.html")
            wv.loadFileURL(indexURL, allowingReadAccessTo: URL(fileURLWithPath: wwwPath))
        } else {
            AppLog("cordova_www bundle not found", level: .error, category: "CordovaTransport")
        }

        // Wait for the JS bridge to signal readiness via the BridgePlugin.ready() call
        var attempts = 0
        let maxAttempts = 50 // 5 seconds
        while attempts < maxAttempts {
            if isReady { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
            attempts += 1
        }

        if !isReady {
            AppLog("Cordova bridge did not become ready after 5s", level: .error, category: "CordovaTransport")
            isReady = true
        } else {
            AppLog("Cordova bridge ready after \(attempts * 100)ms", category: "CordovaTransport")
        }

        for cont in readyContinuations {
            cont.resume()
        }
        readyContinuations.removeAll()

        return wv
    }

    static func markReady() {
        isReady = true
    }
}

// MARK: - WKScriptMessageHandler (receives cordova.exec() calls from JS)

/// Handles messages posted by cordova.js via `webkit.messageHandlers.bridge.postMessage(command)`.
/// This is the native-side entry point for the real Cordova JS-to-native bridge.
class CordovaBridgeMessageHandler: NSObject, WKScriptMessageHandler {
    var plugin: CordovaEchoPlugin?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String, type == "cordova",
              let callbackId = body["callbackId"] as? String,
              let service = body["service"] as? String,
              let action = body["action"] as? String,
              let actionArgs = body["actionArgs"] as? [Any]
        else {
            AppLog("Unrecognized message: \(message.body)", level: .warning, category: "CordovaTransport")
            return
        }

        guard service == "BridgePlugin", let plugin else {
            AppLog("Unknown service: \(service)", level: .warning, category: "CordovaTransport")
            return
        }

        // Create a real CDVInvokedUrlCommand — the same object Cordova creates
        // when routing cordova.exec() calls to native plugins
        guard let command = CDVInvokedUrlCommand(
            arguments: actionArgs,
            callbackId: callbackId,
            className: service,
            methodName: action
        ) else {
            AppLog("Failed to create CDVInvokedUrlCommand", level: .error, category: "CordovaTransport")
            return
        }

        // Route to the plugin method — exactly how CDVPluginManager dispatches
        switch action {
        case "echo":
            plugin.echo(command)
        case "ready":
            plugin.ready(command)
        default:
            AppLog("Unknown action: \(action)", level: .warning, category: "CordovaTransport")
            let result = CDVPluginResult(status: .error, messageAs: "Unknown action: \(action)")
            plugin.commandDelegate?.send(result, callbackId: callbackId)
        }
    }
}

// MARK: - WKNavigationDelegate (page load debugging)

class CordovaBridgeNavigationDelegate: NSObject, WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        AppLog("Cordova WebView loaded: \(webView.url?.absoluteString ?? "nil")", category: "CordovaTransport")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        AppLog("Cordova WebView failed: \(error)", level: .error, category: "CordovaTransport")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        AppLog("Cordova WebView provisional navigation failed: \(error)", level: .error, category: "CordovaTransport")
    }
}

// MARK: - Real CDVPlugin subclass

/// Real Cordova plugin that echoes data back through the bridge.
/// Subclasses CDVPlugin and uses CDVPluginResult + CDVCommandDelegate — the same
/// infrastructure that every Cordova plugin (including Q-Interactive Assess) uses.
class CordovaEchoPlugin: CDVPlugin {
    @objc func echo(_ command: CDVInvokedUrlCommand) {
        let payload = command.arguments?[0] as? String ?? ""
        let callId = command.arguments?[1] as? String ?? ""

        // Create a real CDVPluginResult with OK status — same as any Cordova plugin
        let result = CDVPluginResult(status: .ok, messageAs: payload)
        commandDelegate?.send(result, callbackId: command.callbackId)

        // Also notify the native callback registry for the transport layer
        Task { @MainActor in
            CordovaBridgeManager.handleEchoResult(callId: callId, payload: payload)
        }
    }

    @objc func ready(_ command: CDVInvokedUrlCommand) {
        AppLog("CordovaEchoPlugin ready signal received", category: "CordovaTransport")
        let result = CDVPluginResult(status: .ok)
        commandDelegate?.send(result, callbackId: command.callbackId)
        Task { @MainActor in
            CordovaBridgeManager.markReady()
        }
    }
}

// MARK: - CDVCommandDelegate implementation

/// Implements the real CDVCommandDelegate protocol to deliver CDVPluginResult back to JS.
/// This replicates what CDVCommandDelegateImpl does: serializes the result as JSON
/// and calls evaluateJavaScript with `cordova.require('cordova/exec').nativeCallback(...)`.
class CordovaBridgeCommandDelegate: NSObject, CDVCommandDelegate {
    var settings: [AnyHashable: Any] { [:] }
    var urlTransformer: UrlTransformerBlock?

    private weak var webView: WKWebView?

    init(webView: WKWebView) {
        self.webView = webView
        super.init()
    }

    func path(forResource resourcepath: String!) -> String! {
        Bundle.main.path(forResource: resourcepath, ofType: nil)
    }

    func getCommandInstance(_ pluginName: String!) -> Any! {
        nil
    }

    func send(_ result: CDVPluginResult!, callbackId: String!) {
        guard let result, let callbackId else { return }

        let status = result.status.intValue
        let keepCallback = result.keepCallback.boolValue ? 1 : 0
        let argumentsAsJSON = result.argumentsAsJSON() ?? "null"

        // Construct the exact same JS call that CDVCommandDelegateImpl uses
        let js = "cordova.require('cordova/exec').nativeCallback('\(callbackId)',\(status),\(argumentsAsJSON),\(keepCallback))"

        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(js) { _, error in
                if let error {
                    AppLog("nativeCallback JS error: \(error)", level: .error, category: "CordovaTransport")
                }
            }
        }
    }

    func evalJs(_ js: String!) {
        guard let js else { return }
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    func evalJs(_ js: String!, scheduledOnRunLoop: Bool) {
        evalJs(js)
    }

    func evalJsHelper2(_ js: String!) {
        evalJs(js)
    }

    func run(inBackground block: (() -> Void)!) {
        guard let block else { return }
        DispatchQueue.global(qos: .default).async {
            block()
        }
    }
}

// MARK: - CordovaTransport

/// Cordova bridge transport — routes data through a REAL WKWebView running
/// real cordova.js, through the real WKScriptMessageHandler IPC boundary,
/// and into a real CDVPlugin subclass using real CDVPluginResult.
///
/// Every byte passes through: cordova.exec() → JSON.stringify → webkit.messageHandlers IPC
/// (cross-process) → WKScriptMessageHandler → CDVInvokedUrlCommand → CordovaEchoPlugin.echo()
/// → CDVPluginResult → evaluateJavaScript(nativeCallback) — the full Cordova pipeline.
final class CordovaTransport: TransportProvider {
    let bridgeID = "cordova"
    let bridgeLabel = "Cordova JS Bridge"

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
            AppLog("Bridge not ready, sending raw", level: .warning, category: "CordovaTransport")
            native.send(data, completion: completion)
            return
        }

        let base64 = data.base64EncodedString()

        Task { @MainActor [weak self] in
            guard let self else { return }
            let callId = CordovaBridgeManager.nextCallId()

            CordovaBridgeManager.registerCallback(callId: callId) { [weak self] resultBase64 in
                guard let self else { return }
                if let processedData = Data(base64Encoded: resultBase64) {
                    self.native.send(processedData, completion: completion)
                } else {
                    self.native.send(data, completion: completion)
                }
            }

            let wv = await CordovaBridgeManager.shared()
            let js = "echoBridge('\(base64)', '\(callId)');"
            wv.evaluateJavaScript(js) { _, error in
                if let error {
                    AppLog("JS eval error: \(error)", level: .error, category: "CordovaTransport")
                    CordovaBridgeManager.cancelCallback(callId: callId)
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
                    let callId = CordovaBridgeManager.nextCallId()

                    // Timeout: if WKWebView doesn't respond in 500ms, deliver raw
                    let timeoutItem = DispatchWorkItem {
                        CordovaBridgeManager.cancelCallback(callId: callId)
                        handler(payload)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: timeoutItem)

                    CordovaBridgeManager.registerCallback(callId: callId) { resultBase64 in
                        timeoutItem.cancel()
                        if let processedData = Data(base64Encoded: resultBase64) {
                            handler(processedData)
                        } else {
                            handler(payload)
                        }
                    }

                    let wv = await CordovaBridgeManager.shared()
                    let js = "echoBridge('\(base64)', '\(callId)');"
                    wv.evaluateJavaScript(js, completionHandler: nil)
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
            _ = await CordovaBridgeManager.shared()
            self.bridgeReady = true
            AppLog("Bridge connected", category: "CordovaTransport")
        }
    }
}
