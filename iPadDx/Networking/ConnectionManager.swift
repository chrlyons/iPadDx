import Foundation
import Network

/// Shared TLS-PSK configuration
enum ConnectionSecurity {
    /// Create TLS-PSK parameters for Network.framework connections
    /// - Parameter peerToPeer: Include AWDL/peer-to-peer so connections work over local Wi-Fi
    ///   (without an access point) as well as infrastructure Wi-Fi.
    static func tlsParameters(peerToPeer: Bool = true) -> NWParameters {
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
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 10 // Send keepalive after 10s idle
        tcpOptions.keepaliveInterval = 5 // Retry every 5s
        tcpOptions.keepaliveCount = 3 // Give up after 3 missed
        tcpOptions.noDelay = true // Disable Nagle's algorithm for low-latency pings
        tcpOptions.connectionTimeout = 15 // 15s connection timeout
        let params = NWParameters(tls: tlsOptions, tcp: tcpOptions)
        params.includePeerToPeer = peerToPeer
        return params
    }
}

@Observable
class ConnectionManager {
    var isConnected: Bool = false
    private(set) var totalBytesSent: Int = 0
    private var _totalBytesReceived: Int = 0
    var totalBytesReceived: Int {
        _totalBytesReceived
    }

    var onConnectionLost: (() -> Void)?
    private var receiveHandler: ((Data) -> Void)?
    private let queue = DispatchQueue(label: "com.ipadconnection.connection")
    private var readyContinuation: CheckedContinuation<Bool, Never>?
    let label: String

    /// The bridge transport this connection uses.
    let bridgeTransport: String

    /// The transport provider that handles actual network operations.
    private let transport: TransportProvider

    init(label: String = "unnamed", bridgeTransport: String = "native") {
        self.label = label
        self.bridgeTransport = bridgeTransport
        transport = BridgeRegistry.transport(for: bridgeTransport) ?? NativeTransport()
    }

    func connect(to endpoint: NWEndpoint, handler: @escaping (Data) -> Void) {
        receiveHandler = handler
        AppLog("connect to \(endpoint) [\(bridgeTransport)]", category: "CM:\(label)")
        setupTransportCallbacks()
        transport.connect(to: endpoint, queue: queue)
    }

    func accept(_ conn: NWConnection, handler: @escaping (Data) -> Void) {
        receiveHandler = handler
        AppLog("accept \(conn.endpoint) [\(bridgeTransport)]", category: "CM:\(label)")
        setupTransportCallbacks()
        transport.accept(conn, queue: queue)
    }

    func send(_ message: DiagnosticMessage) {
        guard isConnected else {
            AppLog(
                "send DROPPED (connected=\(isConnected))",
                level: .warning,
                category: "CM:\(label)"
            )
            return
        }
        do {
            let data = try message.encode()
            totalBytesSent += data.count
            transport.send(data) { error in
                if let error {
                    AppLog("Send error: \(error)", level: .error, category: "CM")
                }
            }
        } catch {
            AppLog("Encode error: \(error)", level: .error, category: "CM")
        }
    }

    func disconnect() {
        AppLog("disconnect called", category: "CM:\(label)")
        transport.disconnect()
        Task { @MainActor in
            isConnected = false
        }
    }

    /// Wait for the connection to reach .ready state, or timeout.
    /// Returns true if connected, false if failed/timed out.
    func waitForReady(timeout: TimeInterval = 15) async -> Bool {
        if isConnected {
            AppLog("waitForReady: already connected", category: "CM:\(label)")
            return true
        }
        AppLog("waitForReady: waiting up to \(timeout)s", category: "CM:\(label)")
        let start = Date()
        let result = await withCheckedContinuation { continuation in
            // Re-check after setting continuation to close the race window
            // where .ready fires between the isConnected check and here
            if isConnected {
                continuation.resume(returning: true)
                return
            }
            readyContinuation = continuation

            // Timeout — resolve as failure if still waiting
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if let pending = readyContinuation {
                    readyContinuation = nil
                    AppLog("waitForReady: TIMEOUT after \(timeout)s", level: .error, category: "CM:\(label)")
                    pending.resume(returning: false)
                }
            }
        }
        let elapsed = Date().timeIntervalSince(start)
        AppLog(
            "waitForReady: \(result ? "READY" : "FAILED") in \(String(format: "%.1f", elapsed))s",
            category: "CM:\(label)"
        )
        return result
    }

    var currentPath: NWPath? {
        transport.currentPath
    }

    // MARK: - Private

    private func setupTransportCallbacks() {
        // Wire transport state changes → ConnectionManager state
        transport.onStateChange = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .preparing:
                    AppLog("state: preparing", category: "CM:\(self.label)")
                case .ready:
                    AppLog("state: READY", category: "CM:\(self.label)")
                    self.isConnected = true
                    if let continuation = self.readyContinuation {
                        self.readyContinuation = nil
                        continuation.resume(returning: true)
                    }
                case let .failed(error):
                    AppLog("state: FAILED — \(error)", level: .error, category: "CM:\(self.label)")
                    if let continuation = self.readyContinuation {
                        self.readyContinuation = nil
                        continuation.resume(returning: false)
                    }
                    if self.isConnected {
                        self.isConnected = false
                        self.onConnectionLost?()
                    }
                case .disconnected:
                    AppLog("state: disconnected", category: "CM:\(self.label)")
                    if let continuation = self.readyContinuation {
                        self.readyContinuation = nil
                        continuation.resume(returning: false)
                    }
                    if self.isConnected {
                        self.isConnected = false
                        self.onConnectionLost?()
                    }
                }
            }
        }

        // Wire transport receive → ConnectionManager receive handler
        transport.startReceiving(
            handler: { [weak self] payload in
                guard let self else { return }
                let size = payload.count + 4
                Task { @MainActor in
                    self._totalBytesReceived += size
                    self.receiveHandler?(payload)
                }
            },
            onEOF: { [weak self] in
                AppLog("Receive complete (EOF)", category: "CM:\(self?.label ?? "?")")
                Task { @MainActor in
                    guard let self else { return }
                    if self.isConnected {
                        self.isConnected = false
                        self.onConnectionLost?()
                    }
                }
            },
            onError: { [weak self] error in
                AppLog("Receive error: \(error)", level: .error, category: "CM:\(self?.label ?? "?")")
                Task { @MainActor in
                    guard let self else { return }
                    if self.isConnected {
                        self.isConnected = false
                        self.onConnectionLost?()
                    }
                }
            }
        )
    }
}
