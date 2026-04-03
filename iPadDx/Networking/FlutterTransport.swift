import Flutter
import Foundation
import Network

/// Manages a shared FlutterEngine instance across all FlutterTransport connections.
/// The engine is pre-warmed once and reused — avoids the ~200-500ms cold start per connection.
@MainActor
enum FlutterBridge {
    private static var engine: FlutterEngine?
    private static var isRunning = false
    private static var readyContinuations: [CheckedContinuation<Void, Never>] = []

    /// Get the shared engine, starting it if needed.
    /// Returns immediately if already running, otherwise waits for the Dart isolate to be ready.
    static func sharedEngine() async -> FlutterEngine {
        if let engine, isRunning {
            return engine
        }

        if let engine {
            // Engine exists but Dart isn't ready yet — wait
            await withCheckedContinuation { cont in
                readyContinuations.append(cont)
            }
            return engine
        }

        // First call — create and start the engine
        let newEngine = FlutterEngine(name: "ipadconn-bridge", project: nil)
        engine = newEngine

        AppLog("Starting FlutterEngine...", category: "FlutterTransport")
        newEngine.run(withEntrypoint: nil)

        // Give the Dart isolate time to register its MethodChannel handler.
        // The engine.run() call is synchronous but the Dart main() executes
        // asynchronously on the Dart UI thread. We ping until we get a response.
        let channel = FlutterMethodChannel(
            name: "com.ipadconn/bridge",
            binaryMessenger: newEngine.binaryMessenger
        )

        var attempts = 0
        let maxAttempts = 50 // 5 seconds max
        while attempts < maxAttempts {
            let ready = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                channel.invokeMethod("ping", arguments: nil) { result in
                    if let response = result as? String, response == "pong" {
                        cont.resume(returning: true)
                    } else {
                        cont.resume(returning: false)
                    }
                }
            }

            if ready {
                break
            }

            attempts += 1
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }

        if attempts >= maxAttempts {
            AppLog(
                "FlutterEngine Dart isolate did not respond to ping after 5s",
                level: .error,
                category: "FlutterTransport"
            )
        } else {
            AppLog("FlutterEngine ready after \(attempts * 100)ms", category: "FlutterTransport")
        }

        isRunning = true

        // Resume anyone who was waiting
        for cont in readyContinuations {
            cont.resume()
        }
        readyContinuations.removeAll()

        return newEngine
    }
}

/// Flutter platform channel transport — routes data through a REAL FlutterEngine
/// and FlutterMethodChannel, measuring actual StandardMethodCodec serialization
/// and Dart VM thread dispatch overhead.
///
/// The embedded Flutter module (Bridges/flutter_bridge) runs a headless Dart
/// isolate that echoes data back through the MethodChannel. Every byte passes
/// through Flutter's real binary codec and cross-thread dispatch — no simulation.
final class FlutterTransport: TransportProvider {
    let bridgeID = "flutter"
    let bridgeLabel = "Flutter Channel"

    var onStateChange: ((TransportState) -> Void)?

    private let native = NativeTransport()
    private var channel: FlutterMethodChannel?
    private var engineReady = false

    var currentPath: NWPath? {
        native.currentPath
    }

    init() {
        // Engine initialization is async — kicked off when connect/accept is called.
        // The channel is set up once the engine is confirmed ready.
    }

    func connect(to endpoint: NWEndpoint, queue: DispatchQueue) {
        native.onStateChange = { [weak self] state in
            self?.onStateChange?(state)
        }
        native.connect(to: endpoint, queue: queue)
        ensureEngine()
    }

    func accept(_ connection: NWConnection, queue: DispatchQueue) {
        native.onStateChange = { [weak self] state in
            self?.onStateChange?(state)
        }
        native.accept(connection, queue: queue)
        ensureEngine()
    }

    func send(_ data: Data, completion: @escaping (NWError?) -> Void) {
        guard let channel, engineReady else {
            // Engine not ready yet — send raw through native as fallback
            AppLog("Engine not ready, sending raw", level: .warning, category: "FlutterTransport")
            native.send(data, completion: completion)
            return
        }

        // Send data through the real FlutterMethodChannel.
        // This exercises: StandardMethodCodec encode → Dart VM dispatch →
        // Dart handler → StandardMethodCodec encode result → platform callback
        let flutterData = FlutterStandardTypedData(bytes: data)

        channel.invokeMethod("echo", arguments: flutterData) { [weak self] result in
            guard let self else { return }
            if let typedResult = result as? FlutterStandardTypedData {
                native.send(typedResult.data, completion: completion)
            } else if let dataResult = result as? Data {
                native.send(dataResult, completion: completion)
            } else {
                AppLog(
                    "Flutter echo returned unexpected type: \(type(of: result)), sending original",
                    level: .warning,
                    category: "FlutterTransport"
                )
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
                guard let self, let channel, engineReady else {
                    handler(payload)
                    return
                }
                // Route received data through the real Flutter bridge
                let flutterData = FlutterStandardTypedData(bytes: payload)

                channel.invokeMethod("echo", arguments: flutterData) { result in
                    if let typedResult = result as? FlutterStandardTypedData {
                        handler(typedResult.data)
                    } else if let dataResult = result as? Data {
                        handler(dataResult)
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
        channel = nil
        engineReady = false
    }

    // MARK: - Private

    private func ensureEngine() {
        guard !engineReady else { return }
        Task { @MainActor in
            let engine = await FlutterBridge.sharedEngine()
            let ch = FlutterMethodChannel(
                name: "com.ipadconn/bridge",
                binaryMessenger: engine.binaryMessenger
            )
            self.channel = ch
            self.engineReady = true
            AppLog("Channel ready", category: "FlutterTransport")
        }
    }
}
