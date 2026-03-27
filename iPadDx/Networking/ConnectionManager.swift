import Foundation
import Network

/// Shared TLS-PSK configuration matching the Pearson Q-Interactive Assess connection model
enum ConnectionSecurity {
    /// Create TLS-PSK parameters for Network.framework connections
    static func tlsParameters() -> NWParameters {
        let tlsOptions = NWProtocolTLS.Options()
        let secOptions = tlsOptions.securityProtocolOptions

        // Configure PSK ciphersuite
        sec_protocol_options_append_tls_ciphersuite(
            secOptions,
            tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!
        )

        // Add the pre-shared key and identity
        let pskBytes = Array("iPadDx-2026-diagnostic-psk".utf8)
        let identityBytes = Array("iPadDx".utf8)

        pskBytes.withUnsafeBufferPointer { pskPtr in
            identityBytes.withUnsafeBufferPointer { idPtr in
                let pskDD = pskPtr.baseAddress!.withMemoryRebound(to: UInt8.self, capacity: pskPtr.count) { ptr in
                    DispatchData(bytes: UnsafeBufferPointer(start: ptr, count: pskPtr.count))
                }
                let idDD = idPtr.baseAddress!.withMemoryRebound(to: UInt8.self, capacity: idPtr.count) { ptr in
                    DispatchData(bytes: UnsafeBufferPointer(start: ptr, count: idPtr.count))
                }
                sec_protocol_options_add_pre_shared_key(
                    secOptions,
                    pskDD as __DispatchData,
                    idDD as __DispatchData
                )
            }
        }

        let tcpOptions = NWProtocolTCP.Options()
        let params = NWParameters(tls: tlsOptions, tcp: tcpOptions)
        params.includePeerToPeer = true
        return params
    }
}

@Observable
class ConnectionManager {
    var connection: NWConnection?
    var isConnected: Bool = false
    private(set) var totalBytesSent: Int = 0
    private var _totalBytesReceived: Int = 0
    var totalBytesReceived: Int {
        _totalBytesReceived
    }

    var onConnectionLost: (() -> Void)?
    private var receiveHandler: ((Data) -> Void)?
    private let queue = DispatchQueue(label: "com.ipadconnection.connection")

    func connect(to endpoint: NWEndpoint, handler: @escaping (Data) -> Void) {
        receiveHandler = handler
        let params = ConnectionSecurity.tlsParameters()
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
                    if self?.isConnected == true {
                        self?.isConnected = false
                        self?.onConnectionLost?()
                    }
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
