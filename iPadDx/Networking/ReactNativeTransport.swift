import Foundation
import JavaScriptCore
import Network

/// React Native bridge transport — routes data through a JavaScriptCore context
/// replicating React Native's actual bridge architecture (MessageQueue/BatchedBridge).
///
/// Real React Native apps use this flow for the bridge (non-JSI) architecture:
///   JS: NativeModules.Plugin.send(data)
///     → MessageQueue enqueues [moduleID, methodID, args]
///     → On flush: JSON.stringify entire batch → native
///     → Native: RCTBatchedBridge deserializes JSON batch
///     → Finds module by ID, invokes method with args
///     → Result: enqueue callback [callbackID, args]
///     → JSON.stringify → JS
///     → MessageQueue invokes stored callback by ID
///
/// The new JSI/TurboModules architecture bypasses JSON serialization with
/// direct C++ JSI bindings. This transport measures the bridge (legacy)
/// architecture overhead since it's the path that adds measurable latency.
final class ReactNativeTransport: TransportProvider {
    let bridgeID = "reactnative"
    let bridgeLabel = "React Native Bridge"

    var onStateChange: ((TransportState) -> Void)?

    private let native = NativeTransport()
    private let jsContext: JSContext

    var currentPath: NWPath? {
        native.currentPath
    }

    init() {
        jsContext = JSContext()!
        jsContext.exceptionHandler = { _, exception in
            AppLog(
                "RNTransport JSContext error: \(exception?.toString() ?? "unknown")",
                level: .error,
                category: "RNTransport"
            )
        }
        loadRNBridge()
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
        let result = jsContext.evaluateScript("__rnBridge.execSend('\(base64)')")
        guard let processed = result?.toString(),
              let processedData = Data(base64Encoded: processed)
        else {
            native.send(data, completion: completion)
            return
        }
        native.send(processedData, completion: completion)
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
                let result = jsContext.evaluateScript("__rnBridge.execReceive('\(base64)')")
                if let processed = result?.toString(),
                   let processedData = Data(base64Encoded: processed)
                {
                    handler(processedData)
                } else {
                    handler(payload)
                }
            },
            onEOF: onEOF,
            onError: onError
        )
    }

    func disconnect() {
        native.disconnect()
    }

    // MARK: - RN Bridge JS

    /// Loads a faithful replication of React Native's BatchedBridge/MessageQueue.
    /// Models the actual JS→Native→JS pipeline:
    ///   - Module registry with numeric IDs (RCTModuleData)
    ///   - Method registry with numeric IDs
    ///   - Call queue: [moduleID, methodID, params] tuples
    ///   - JSON batch serialization on flush
    ///   - Callback registry with callbackID
    ///   - Response queue: [cbID, args] tuples
    private func loadRNBridge() {
        let js = """
        var __MessageQueue = {
            // Module registry (mirrors RCTModuleData)
            _moduleTable: {},
            _moduleIDMap: {},
            _nextModuleID: 0,

            // Method registry
            _methodTable: {},

            // Callback registry
            _callbacks: {},
            _nextCallbackID: 0,
            _failureCallbacks: {},

            // Call queue (JS → Native)
            _queue: [[], [], [], 0],  // [moduleIDs, methodIDs, params, callID]

            // Register a native module (mirrors RCTBatchedBridge registerModules)
            registerModule: function(name, methods) {
                var moduleID = this._nextModuleID++;
                this._moduleTable[moduleID] = { name: name, methods: methods };
                this._moduleIDMap[name] = moduleID;

                var methodIDs = {};
                for (var i = 0; i < methods.length; i++) {
                    methodIDs[methods[i]] = i;
                }
                this._methodTable[moduleID] = methodIDs;

                return moduleID;
            },

            // Enqueue a call (mirrors MessageQueue.enqueueNativeCall)
            enqueueNativeCall: function(moduleName, methodName, args, onSuccess, onFail) {
                var moduleID = this._moduleIDMap[moduleName];
                var methodID = this._methodTable[moduleID][methodName];

                // Register callbacks
                var cbID = this._nextCallbackID++;
                if (onFail) {
                    this._callbacks[cbID] = onFail;
                    cbID = this._nextCallbackID++;
                }
                if (onSuccess) {
                    this._callbacks[cbID] = onSuccess;
                }

                // Enqueue: [moduleID, methodID, params]
                this._queue[0].push(moduleID);
                this._queue[1].push(methodID);
                this._queue[2].push(args);

                return cbID;
            },

            // Flush queue to native (mirrors MessageQueue.flushedQueue)
            flushedQueue: function() {
                var queue = this._queue;
                this._queue = [[], [], [], this._queue[3] + 1];
                return JSON.stringify(queue);
            },

            // Native invokes JS callback (mirrors MessageQueue.invokeCallbackAndReturnFlushedQueue)
            invokeCallback: function(cbID, args) {
                var callback = this._callbacks[cbID];
                if (callback) {
                    callback.apply(null, args);
                    delete this._callbacks[cbID];
                }
            }
        };

        // Register the network diagnostic module
        var NativeModules = {};
        (function() {
            var moduleID = __MessageQueue.registerModule(
                'NetworkDiagnosticModule',
                ['send', 'onDataReceived']
            );

            NativeModules.NetworkDiagnosticModule = {
                send: function(data) {
                    return new Promise(function(resolve, reject) {
                        __MessageQueue.enqueueNativeCall(
                            'NetworkDiagnosticModule', 'send',
                            [data], resolve, reject
                        );
                    });
                }
            };
        })();

        // Bridge interface for Swift
        var __rnBridge = {
            execSend: function(base64Data) {
                var resultData = null;

                // 1. JS calls NativeModule method (enqueues in MessageQueue)
                var cbID = __MessageQueue.enqueueNativeCall(
                    'NetworkDiagnosticModule', 'send',
                    [base64Data],
                    function(data) { resultData = data; },
                    function(err) { resultData = base64Data; }
                );

                // 2. Flush queue (native calls flushedQueue on timer or event)
                var batchJSON = __MessageQueue.flushedQueue();

                // 3. Native side: deserialize the batch
                var batch = JSON.parse(batchJSON);
                var moduleIDs = batch[0];
                var methodIDs = batch[1];
                var params = batch[2];

                // 4. Find the last call's args
                var lastIdx = moduleIDs.length - 1;
                var callArgs = params[lastIdx];
                var payload = callArgs[0];

                // 5. "Native module executes" — prepare callback args
                var callbackArgs = [payload];

                // 6. Invoke callback (native calls invokeCallback)
                __MessageQueue.invokeCallback(cbID, callbackArgs);

                return resultData;
            },

            execReceive: function(base64Data) {
                var resultData = null;

                // Same pipeline for incoming data (native → JS event)
                var cbID = __MessageQueue.enqueueNativeCall(
                    'NetworkDiagnosticModule', 'onDataReceived',
                    [base64Data],
                    function(data) { resultData = data; },
                    function(err) { resultData = base64Data; }
                );

                var batchJSON = __MessageQueue.flushedQueue();
                var batch = JSON.parse(batchJSON);
                var params = batch[2];
                var lastIdx = batch[0].length - 1;
                var payload = params[lastIdx][0];

                __MessageQueue.invokeCallback(cbID, [payload]);

                return resultData;
            }
        };
        """
        jsContext.evaluateScript(js)
    }
}
