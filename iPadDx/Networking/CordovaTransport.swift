import Foundation
import JavaScriptCore
import Network

/// Cordova bridge transport — routes data through a JavaScriptCore context
/// replicating Cordova's actual plugin bridge architecture.
///
/// Real Cordova iOS apps (including Assess 2.0) use this flow:
///   JS: cordova.exec(success, error, 'Plugin', 'action', [args])
///     → cordova.js serializes into the command queue as JSON
///     → commandQueue is flushed: JSON string sent to native via iOSExec
///     → Native: CDVCommandDelegateImpl deserializes JSON
///     → Plugin executes, creates CDVPluginResult
///     → CDVPluginResult serialized as JSON
///     → evaluateJavaScript callback fires in JS context
///     → JS: success/error callback executes
///
/// This transport runs that same pipeline through a real JSContext.
final class CordovaTransport: TransportProvider {
    let bridgeID = "cordova"
    let bridgeLabel = "Cordova JS Bridge"

    var onStateChange: ((TransportState) -> Void)?

    private let native = NativeTransport()
    private let jsContext: JSContext
    private let jsQueue = DispatchQueue(label: "com.ipadconn.cordova-jscontext")

    var currentPath: NWPath? {
        native.currentPath
    }

    init() {
        jsContext = JSContext()!
        jsContext.exceptionHandler = { _, exception in
            AppLog(
                "CordovaTransport JSContext error: \(exception?.toString() ?? "unknown")",
                level: .error,
                category: "CordovaTransport"
            )
        }
        loadCordovaBridge()
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
        // Replicate: JS cordova.exec() → serialize → native receive → plugin execute → result
        let base64 = data.base64EncodedString()
        jsQueue.async { [weak self] in
            guard let self else { return }
            let result = jsContext.evaluateScript("cordova.__bridge.execSend('\(base64)')")
            if let processed = result?.toString(),
               let processedData = Data(base64Encoded: processed)
            {
                native.send(processedData, completion: completion)
            } else {
                AppLog("Cordova execSend failed, sending raw", level: .warning, category: "CordovaTransport")
                native.send(data, completion: completion)
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
                guard let self else {
                    handler(payload)
                    return
                }
                // Replicate: native fires event → serialize → JS receives → deserialize → callback
                let base64 = payload.base64EncodedString()
                jsQueue.sync {
                    let result = self.jsContext.evaluateScript("cordova.__bridge.execReceive('\(base64)')")
                    if let processed = result?.toString(),
                       let processedData = Data(base64Encoded: processed)
                    {
                        handler(processedData)
                    } else {
                        handler(payload)
                    }
                }
            },
            onEOF: onEOF,
            onError: onError
        )
    }

    func disconnect() {
        native.disconnect()
    }

    // MARK: - Cordova Bridge JS

    /// Loads a faithful replication of Cordova's iOS bridge architecture.
    /// Models the actual cordova.js exec/callback pipeline:
    ///   - cordova.exec() with callbackId, service, action, args
    ///   - Command queue (JSON array of commands)
    ///   - commandQueue flush to native (JSON.stringify of batch)
    ///   - Native-side deserialization (JSON.parse)
    ///   - CDVPluginResult construction with status, message, keepCallback
    ///   - Result serialization back to JS (JSON.stringify)
    ///   - Callback dispatch via callbackId lookup
    private func loadCordovaBridge() {
        let js = """
        var cordova = {
            callbacks: {},
            callbackId: 0,
            commandQueue: [],
            callbackStatus: {
                NO_RESULT: 0,
                OK: 1,
                CLASS_NOT_FOUND_EXCEPTION: 2,
                ILLEGAL_ACCESS_EXCEPTION: 3,
                INSTANTIATION_EXCEPTION: 4,
                MALFORMED_URL_EXCEPTION: 5,
                IO_EXCEPTION: 6,
                INVALID_ACTION: 7,
                JSON_EXCEPTION: 8,
                ERROR: 9
            },

            // Replicates cordova.exec(success, error, service, action, args)
            exec: function(success, error, service, action, args) {
                var callbackId = 'cb' + (++this.callbackId);
                this.callbacks[callbackId] = { success: success, error: error };

                // Build command in Cordova's format
                var command = [callbackId, service, action, JSON.stringify(args)];
                this.commandQueue.push(JSON.stringify(command));

                return callbackId;
            },

            // Replicates nativeFetchMessages — native pulls queued commands
            fetchMessages: function() {
                var messages = '[' + this.commandQueue.join(',') + ']';
                this.commandQueue = [];
                return messages;
            },

            // Replicates nativeCallback — native returns result to JS
            callbackFromNative: function(callbackId, pluginResult) {
                var callback = this.callbacks[callbackId];
                if (!callback) return;

                var result = JSON.parse(pluginResult);
                if (result.status === this.callbackStatus.OK) {
                    if (callback.success) callback.success(result.message);
                } else {
                    if (callback.error) callback.error(result.message);
                }

                if (!result.keepCallback) {
                    delete this.callbacks[callbackId];
                }
            },

            // Bridge interface called from Swift
            __bridge: {
                // Send path: exec() → queue → flush → deserialize → re-serialize result → callback
                execSend: function(base64Data) {
                    var resultData = null;

                    // 1. JS calls exec (as a Cordova plugin would)
                    var callbackId = cordova.exec(
                        function(data) { resultData = data; },
                        function(err) { resultData = err; },
                        'NetworkDiagnosticPlugin',
                        'send',
                        [base64Data]
                    );

                    // 2. Flush command queue (native would call fetchMessages)
                    var messages = cordova.fetchMessages();

                    // 3. Native side: parse the command batch
                    var batch = JSON.parse(messages);
                    var cmd = JSON.parse(batch[batch.length - 1]);
                    var args = JSON.parse(cmd[3]);
                    var payload = args[0];

                    // 4. "Plugin executes" — build CDVPluginResult
                    var pluginResult = JSON.stringify({
                        status: cordova.callbackStatus.OK,
                        message: payload,
                        keepCallback: false
                    });

                    // 5. Return result via callback (evaluateJavaScript in real Cordova)
                    cordova.callbackFromNative(callbackId, pluginResult);

                    // 6. Return the data that was received by the success callback
                    return resultData;
                },

                // Receive path: native fires event → serialize → JS handler → callback
                execReceive: function(base64Data) {
                    var resultData = null;

                    // 1. Native creates event (like CDVPlugin sendPluginResult)
                    var callbackId = cordova.exec(
                        function(data) { resultData = data; },
                        function(err) { resultData = err; },
                        'NetworkDiagnosticPlugin',
                        'onDataReceived',
                        [base64Data]
                    );

                    // 2. Flush
                    var messages = cordova.fetchMessages();

                    // 3. Parse batch
                    var batch = JSON.parse(messages);
                    var cmd = JSON.parse(batch[batch.length - 1]);
                    var args = JSON.parse(cmd[3]);
                    var payload = args[0];

                    // 4. Build result
                    var pluginResult = JSON.stringify({
                        status: cordova.callbackStatus.OK,
                        message: payload,
                        keepCallback: false
                    });

                    // 5. Dispatch callback
                    cordova.callbackFromNative(callbackId, pluginResult);

                    return resultData;
                }
            }
        };
        """
        jsContext.evaluateScript(js)
    }
}
