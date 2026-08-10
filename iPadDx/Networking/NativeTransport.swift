import Foundation
import Network

/// Direct Network.framework transport — no bridge overhead.
/// This is the baseline transport that all other bridges are compared against.
final class NativeTransport: TransportProvider {
    let bridgeID = "native"
    let bridgeLabel = "Native (baseline)"

    /// Largest frame accepted off the wire. Throughput tests legitimately send
    /// multi-megabyte payloads, so this is deliberately generous — it exists to
    /// stop a corrupt or hostile length prefix from requesting an absurd
    /// allocation, not to constrain real traffic.
    static let maxFrameLength = 64 * 1024 * 1024 // 64 MB

    var onStateChange: ((TransportState) -> Void)?

    private var connection: NWConnection?
    private var queue: DispatchQueue?

    // Deferred receive — stored until connection is ready
    private var pendingReceiveHandler: ((Data) -> Void)?
    private var pendingOnEOF: (() -> Void)?
    private var pendingOnError: ((NWError) -> Void)?

    var currentPath: NWPath? {
        connection?.currentPath
    }

    func connect(to endpoint: NWEndpoint, queue: DispatchQueue) {
        self.queue = queue
        let params = ConnectionSecurity.tlsParameters()
        let conn = NWConnection(to: endpoint, using: params)
        connection = conn
        setupStateHandler(conn)
        conn.start(queue: queue)
    }

    func accept(_ conn: NWConnection, queue: DispatchQueue) {
        self.queue = queue
        connection = conn
        setupStateHandler(conn)
        conn.start(queue: queue)
    }

    func send(_ data: Data, completion: @escaping (NWError?) -> Void) {
        connection?.send(content: data, completion: .contentProcessed { error in
            completion(error)
        })
    }

    func startReceiving(
        handler: @escaping (Data) -> Void,
        onEOF: @escaping () -> Void,
        onError: @escaping (NWError) -> Void
    ) {
        if let conn = connection {
            // Connection already exists — start immediately
            receiveFrame(conn: conn, handler: handler, onEOF: onEOF, onError: onError)
        } else {
            // Connection not yet created — defer until ready
            pendingReceiveHandler = handler
            pendingOnEOF = onEOF
            pendingOnError = onError
        }
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        pendingReceiveHandler = nil
        pendingOnEOF = nil
        pendingOnError = nil
    }

    // MARK: - Private

    private func setupStateHandler(_ conn: NWConnection) {
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .setup:
                AppLog("state: setup", category: "NativeTransport")
            case .preparing:
                self?.onStateChange?(.preparing)
            case .ready:
                self?.onStateChange?(.ready)
                // Start deferred receive loop now that connection is ready
                if let handler = self?.pendingReceiveHandler,
                   let onEOF = self?.pendingOnEOF,
                   let onError = self?.pendingOnError
                {
                    self?.pendingReceiveHandler = nil
                    self?.pendingOnEOF = nil
                    self?.pendingOnError = nil
                    self?.receiveFrame(conn: conn, handler: handler, onEOF: onEOF, onError: onError)
                }
            case let .failed(error):
                self?.onStateChange?(.failed(error))
            case .cancelled:
                self?.onStateChange?(.disconnected)
            case let .waiting(error):
                AppLog("state: waiting — \(error)", level: .warning, category: "NativeTransport")
            @unknown default:
                AppLog("state: unknown", category: "NativeTransport")
            }
        }

        conn.pathUpdateHandler = { path in
            AppLog(
                "path: \(path.status), ifaces: \(path.availableInterfaces.map { "\($0.type)" })",
                category: "NativeTransport"
            )
        }
    }

    /// Read a 4-byte length prefix, then the payload.
    private func receiveFrame(
        conn: NWConnection,
        handler: @escaping (Data) -> Void,
        onEOF: @escaping () -> Void,
        onError: @escaping (NWError) -> Void
    ) {
        conn.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            if let error {
                onError(error)
                return
            }

            guard let lengthData = data, lengthData.count == 4 else {
                if isComplete {
                    onEOF()
                } else {
                    self?.receiveFrame(conn: conn, handler: handler, onEOF: onEOF, onError: onError)
                }
                return
            }

            let length = Int(lengthData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian })

            // The length comes straight off the wire: 0 traps inside
            // NWConnection (invalid parameter) and an absurd value would ask
            // for a huge allocation. Either means the stream is desynced or
            // corrupt, and nothing useful can be read after it — log and close
            // the connection instead of trapping or reading garbage.
            guard length > 0, length <= Self.maxFrameLength else {
                AppLog(
                    "invalid frame length \(length) (max \(Self.maxFrameLength)) — closing connection",
                    level: .error,
                    category: "NativeTransport"
                )
                conn.cancel()
                onError(length == 0 ? .posix(.EBADMSG) : .posix(.EMSGSIZE))
                return
            }

            conn.receive(
                minimumIncompleteLength: length,
                maximumLength: length
            ) { [weak self] payload, _, isComplete2, error in
                if let error {
                    onError(error)
                    return
                }

                if let payload {
                    handler(payload)
                }

                if isComplete2 {
                    onEOF()
                } else {
                    self?.receiveFrame(conn: conn, handler: handler, onEOF: onEOF, onError: onError)
                }
            }
        }
    }
}
