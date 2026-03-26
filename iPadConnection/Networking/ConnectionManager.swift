import Foundation
import Network

@Observable
class ConnectionManager {
    var connection: NWConnection?
    var isConnected: Bool = false
    private(set) var totalBytesSent: Int = 0
    private var _totalBytesReceived: Int = 0
    var totalBytesReceived: Int {
        _totalBytesReceived
    }

    private var receiveHandler: ((Data) -> Void)?
    private let queue = DispatchQueue(label: "com.ipadconnection.connection")

    func connect(to endpoint: NWEndpoint, handler: @escaping (Data) -> Void) {
        receiveHandler = handler
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let conn = NWConnection(to: endpoint, using: params)
        connection = conn
        setupConnection(conn)
        conn.start(queue: queue)
    }

    func accept(_ conn: NWConnection, handler: @escaping (Data) -> Void) {
        receiveHandler = handler
        connection = conn
        setupConnection(conn)
        conn.start(queue: queue)
    }

    func send(_ message: DiagnosticMessage) {
        guard let conn = connection, isConnected else { return }
        do {
            let data = try message.encode()
            totalBytesSent += data.count
            conn.send(content: data, completion: .contentProcessed { error in
                if let error {
                    print("Send error: \(error)")
                }
            })
        } catch {
            print("Encode error: \(error)")
        }
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        Task { @MainActor in
            isConnected = false
        }
    }

    var currentPath: NWPath? {
        connection?.currentPath
    }

    // MARK: - Private

    private func setupConnection(_ conn: NWConnection) {
        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    self?.isConnected = true
                case .failed, .cancelled:
                    self?.isConnected = false
                default:
                    break
                }
            }
        }

        conn.pathUpdateHandler = { path in
            print("Path updated: \(path.status), expensive: \(path.isExpensive)")
        }

        startReceiving(conn)
    }

    private func startReceiving(_ conn: NWConnection) {
        // Read 4-byte length prefix
        conn.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let error {
                print("Receive error: \(error)")
                Task { @MainActor in self.isConnected = false }
                return
            }

            guard let lengthData = data, lengthData.count == 4 else {
                if isComplete {
                    Task { @MainActor in self.isConnected = false }
                } else {
                    startReceiving(conn)
                }
                return
            }

            let length = lengthData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }

            // Read message payload
            conn
                .receive(
                    minimumIncompleteLength: Int(length),
                    maximumLength: Int(length)
                ) { [weak self] payload, _, isComplete2, error in
                    guard let self else { return }

                    if let error {
                        print("Payload receive error: \(error)")
                        Task { @MainActor in self.isConnected = false }
                        return
                    }

                    if let payload {
                        _totalBytesReceived += payload.count + 4
                        Task { @MainActor in
                            self.receiveHandler?(payload)
                        }
                    }

                    // Always continue receiving as long as the connection isn't done
                    if isComplete2 {
                        Task { @MainActor in self.isConnected = false }
                    } else {
                        startReceiving(conn)
                    }
                }
        }
    }
}
