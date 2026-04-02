import Foundation
import Network
import WebKit

/// Capacitor bridge transport — routes data through WKWebView replicating
/// Capacitor's actual native bridge architecture.
///
/// Real Capacitor apps use this flow:
///   JS: Capacitor.toNative('Plugin', 'method', { data }, callbackId)
///     → window.webkit.messageHandlers.bridge.postMessage(msg)
///     → [WebKit IPC: WebContent process → App process]
///     → CAPBridge receives WKScriptMessage
///     → CAPBridge deserializes, finds plugin, invokes method
///     → Plugin creates CAPPluginCallResult
///     → CAPBridge serializes result as JSON
///     → webView.evaluateJavaScript("window.Capacitor.fromNative(...)")
///     → [WebKit IPC: App process → WebContent process]
///     → JS Capacitor.fromNative dispatches to stored callback
///
/// This transport uses a real WKWebView so the cross-process IPC overhead
/// (the dominant cost) is genuine — not simulated.
final class CapacitorTransport: TransportProvider {
    let bridgeID = "capacitor"
    let bridgeLabel = "Capacitor Bridge"

    var onStateChange: ((TransportState) -> Void)?

    private let native = NativeTransport()
    private var webView: WKWebView?
    private let messageHandler = CapacitorMessageHandler()
    private var isReady = false
    private var readyContinuation: CheckedContinuation<Void, Never>?

    var currentPath: NWPath? {
        native.currentPath
    }

    init() {
        Task { @MainActor in
            let config = WKWebViewConfiguration()
            config.userContentController.add(self.messageHandler, name: "bridge")
            let wv = WKWebView(frame: .zero, configuration: config)
            self.webView = wv
            wv.loadHTMLString(Self.bridgeHTML, baseURL: nil)

            self.messageHandler.onReady = { [weak self] in
                self?.isReady = true
                self?.readyContinuation?.resume()
                self?.readyContinuation = nil
            }
        }
    }

    /// Wait for the WKWebView and JS bridge to be fully loaded.
    private func ensureReady() async {
        if isReady { return }
        await withCheckedContinuation { continuation in
            if isReady {
                continuation.resume()
                return
            }
            readyContinuation = continuation
        }
    }

    func connect(to endpoint: NWEndpoint, queue: DispatchQueue) {
        native.onStateChange = { [weak self] state in
            self?.onStateChange?(state)
        }
        native.connect(to: endpoint, queue: queue)
    }

    func accept(_ connection: NWConnection, queue: DispatchQueue) {
        native.onStateChange = { [weak self] state in
            self?.onStateChange?(state)
        }
        native.accept(connection, queue: queue)
    }

    func send(_ data: Data, completion: @escaping (NWError?) -> Void) {
        let base64 = data.base64EncodedString()
        let callId = messageHandler.nextCallId()

        messageHandler.registerCallback(callId: callId) { [weak self] resultBase64 in
            guard let self else { return }
            if let processedData = Data(base64Encoded: resultBase64) {
                native.send(processedData, completion: completion)
            } else {
                native.send(data, completion: completion)
            }
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            await ensureReady()
            let js = """
            Capacitor.toNative('NetworkDiagnosticPlugin', 'send', { payload: '\(base64)' }, '\(callId)');
            """
            webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    func startReceiving(
        handler: @escaping (Data) -> Void,
        onEOF: @escaping () -> Void,
        onError: @escaping (NWError) -> Void
    ) {
        native.startReceiving(
            handler: { [weak self] payload in
                guard let self else {
                    handler(payload)
                    return
                }
                let base64 = payload.base64EncodedString()
                let callId = messageHandler.nextCallId()

                // Timeout: if WKWebView doesn't respond in 500ms, deliver raw payload
                let timeoutItem = DispatchWorkItem { [weak self] in
                    self?.messageHandler.cancelCallback(callId: callId)
                    handler(payload)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: timeoutItem)

                messageHandler.registerCallback(callId: callId) { resultBase64 in
                    timeoutItem.cancel()
                    if let processedData = Data(base64Encoded: resultBase64) {
                        handler(processedData)
                    } else {
                        handler(payload)
                    }
                }

                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await ensureReady()
                    let js = """
                    Capacitor.triggerEvent('dataReceived', 'NetworkDiagnosticPlugin', { payload: '\(base64)', callId: '\(
                        callId
                    )' });
                    """
                    webView?.evaluateJavaScript(js, completionHandler: nil)
                }
            },
            onEOF: onEOF,
            onError: onError
        )
    }

    func disconnect() {
        native.disconnect()
        Task { @MainActor [weak self] in
            self?.webView?.stopLoading()
            self?.webView = nil
        }
    }

    // MARK: - Capacitor Bridge HTML

    private static let bridgeHTML = """
    <html><body><script>
    var Capacitor = {
        callbacks: {},
        callbackIdCount: 0,
        eventListeners: {},

        toNative: function(pluginId, methodName, options, callbackId) {
            var call = {
                callbackId: callbackId,
                pluginId: pluginId,
                methodName: methodName,
                options: options
            };
            this.callbacks[callbackId] = true;
            var serialized = JSON.stringify(call);
            window.webkit.messageHandlers.bridge.postMessage({
                type: 'call',
                callbackId: callbackId,
                pluginId: pluginId,
                methodName: methodName,
                options: serialized
            });
        },

        fromNative: function(result) {
            var resultObj = (typeof result === 'string') ? JSON.parse(result) : result;
            var callbackId = resultObj.callbackId;
            if (this.callbacks[callbackId]) {
                if (!resultObj.keepCallback) {
                    delete this.callbacks[callbackId];
                }
            }
        },

        triggerEvent: function(eventName, pluginId, data) {
            var event = JSON.stringify({
                eventName: eventName,
                pluginId: pluginId,
                data: data
            });
            var parsed = JSON.parse(event);
            window.webkit.messageHandlers.bridge.postMessage({
                type: 'eventResult',
                callId: data.callId,
                data: parsed.data.payload
            });
        }
    };

    window.webkit.messageHandlers.bridge.postMessage({ type: 'ready' });
    </script></body></html>
    """
}

/// Handles WKScriptMessage from the Capacitor bridge WebView.
private class CapacitorMessageHandler: NSObject, WKScriptMessageHandler {
    var onReady: (() -> Void)?
    private var callbacks: [String: (String) -> Void] = [:]
    private var _nextId: Int = 0
    private let lock = NSLock()

    func nextCallId() -> String {
        lock.lock()
        defer { lock.unlock() }
        _nextId += 1
        return "cap_\(_nextId)"
    }

    func registerCallback(callId: String, callback: @escaping (String) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        callbacks[callId] = callback
    }

    func cancelCallback(callId: String) {
        lock.lock()
        defer { lock.unlock() }
        callbacks.removeValue(forKey: callId)
    }

    func userContentController(
        _: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any] else { return }
        let type = body["type"] as? String ?? ""

        switch type {
        case "ready":
            onReady?()
            onReady = nil

        case "call":
            guard let callbackId = body["callbackId"] as? String,
                  let optionsJSON = body["options"] as? String
            else { return }

            guard let optionsData = optionsJSON.data(using: .utf8),
                  let options = try? JSONSerialization.jsonObject(with: optionsData) as? [String: Any],
                  let payload = options["options"] as? [String: Any],
                  let data = payload["payload"] as? String
            else { return }

            let result: [String: Any] = [
                "callbackId": callbackId,
                "methodName": body["methodName"] as? String ?? "",
                "success": true,
                "data": ["payload": data],
            ]

            if let resultJSON = try? JSONSerialization.data(withJSONObject: result),
               let resultStr = String(data: resultJSON, encoding: .utf8)
            {
                let escapedResult = resultStr.replacingOccurrences(of: "'", with: "\\'")
                Task { @MainActor in
                    let webView = (message.webView)
                    webView?.evaluateJavaScript("Capacitor.fromNative('\(escapedResult)')")
                }
            }

            lock.lock()
            let callback = callbacks.removeValue(forKey: callbackId)
            lock.unlock()
            callback?(data)

        case "eventResult":
            guard let callId = body["callId"] as? String,
                  let data = body["data"] as? String
            else { return }
            lock.lock()
            let callback = callbacks.removeValue(forKey: callId)
            lock.unlock()
            callback?(data)

        default:
            break
        }
    }
}
