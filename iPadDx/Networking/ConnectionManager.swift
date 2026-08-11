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
        guard let ciphersuite = tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256)) else {
            AppLog("PSK ciphersuite unavailable — falling back to default TLS", level: .error, category: "Security")
            return NWParameters(tls: tlsOptions)
        }
        sec_protocol_options_append_tls_ciphersuite(secOptions, ciphersuite)

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
    /// Reports why the connection ended, so the owner can record it in the
    /// disconnect history. Fires once per lost connection, before `onConnectionLost`.
    var onDisconnect: ((DisconnectReason, String) -> Void)?
    var lastDisconnectReason: DisconnectReason = .unknown
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
        if let resolved = BridgeRegistry.transport(for: bridgeTransport) {
            self.bridgeTransport = bridgeTransport
            transport = resolved
        } else {
            AppLog(
                "Bridge '\(bridgeTransport)' unavailable, falling back to native",
                level: .warning,
                category: "CM:\(label)"
            )
            self.bridgeTransport = "native"
            transport = NativeTransport()
        }
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

    /// Sends a message. Returns false if it could not be queued (not connected, or encode failed).
    /// `completion` is invoked only when the message was actually handed to the transport.
    @discardableResult
    func send(_ message: DiagnosticMessage, completion: ((NWError?) -> Void)? = nil) -> Bool {
        guard isConnected else {
            AppLog(
                "send DROPPED (connected=\(isConnected))",
                level: .warning,
                category: "CM:\(label)"
            )
            return false
        }
        do {
            let data = try message.encode()
            totalBytesSent += data.count
            transport.send(data) { error in
                if let error {
                    AppLog("Send error: \(error)", level: .error, category: "CM")
                }
                completion?(error)
            }
            return true
        } catch {
            AppLog("Encode error: \(error)", level: .error, category: "CM")
            return false
        }
    }

    /// Resumes a continuation exactly once, from any thread.
    ///
    /// The transport completion and the watchdog run on different queues and either can
    /// win, so the guard has to be thread-safe: resuming twice traps, resuming never hangs.
    private final class SingleResume: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?

        init(_ continuation: CheckedContinuation<Bool, Never>) {
            self.continuation = continuation
        }

        /// Returns true if this call actually consumed the continuation.
        @discardableResult
        func resume(_ value: Bool) -> Bool {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: value)
            return pending != nil
        }
    }

    /// Sends a message and waits until the transport has accepted it.
    ///
    /// Used by the throughput phases so that a large transfer applies real backpressure
    /// instead of queueing every chunk in memory at once. Returns false if the message
    /// could not be queued, or if the transport never reported completion within
    /// `timeout` — a bridge whose JS/Dart callback is lost, or a connection cancelled
    /// mid-send, must not strand the whole test suite.
    func sendAwaitingCompletion(_ message: DiagnosticMessage, timeout: TimeInterval = 20) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = SingleResume(continuation)
            let queued = send(message) { error in
                once.resume(error == nil)
            }
            if !queued {
                once.resume(false)
                return
            }
            // Only report a timeout if it actually fired first — logging unconditionally
            // would emit a spurious warning for every successful send, flooding the log
            // and adding main-actor work in the middle of a measurement.
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                if once.resume(false) {
                    AppLog(
                        "send timed out after \(Int(timeout))s — transport never reported completion",
                        level: .warning,
                        category: "CM:\(self?.label ?? "?")"
                    )
                }
            }
        }
    }

    func disconnect() {
        AppLog("disconnect called", category: "CM:\(label)")
        lastDisconnectReason = .userInitiated
        transport.disconnect()
        Task { @MainActor in
            isConnected = false
        }
    }

    /// Classifies a transport error into a disconnect reason.
    ///
    /// Pattern-matches the real `NWError` cases rather than searching the error's
    /// description for substrings — the old approach matched "61" anywhere in the
    /// text and mistook unrelated errors for connection-refused.
    static func classifyError(_ error: Error) -> DisconnectReason {
        guard let nwError = error as? NWError else { return .networkError }
        switch nwError {
        case let .posix(code):
            switch code {
            case .ECONNREFUSED:
                return .connectionRefused
            case .ETIMEDOUT:
                return .keepaliveTimeout
            case .ENETDOWN, .ENETUNREACH, .EHOSTUNREACH, .ENETRESET:
                return .pathChanged
            case .ECONNRESET, .ECONNABORTED, .EPIPE, .ENOTCONN:
                return .remoteDisconnect
            default:
                return .networkError
            }
        case .tls:
            return .tlsError
        case .dns:
            return .networkError
        @unknown default:
            return .networkError
        }
    }

    /// Human-readable detail for the disconnect history.
    static func describeError(_ error: Error) -> String {
        if let nwError = error as? NWError {
            switch nwError {
            case let .posix(code): return "POSIX \(code)"
            case let .tls(status): return "TLS status \(status)"
            case let .dns(type): return "DNS error \(type)"
            @unknown default: return String(describing: nwError)
            }
        }
        return String(describing: error)
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
                    self.lastDisconnectReason = ConnectionManager.classifyError(error)
                    if let continuation = self.readyContinuation {
                        self.readyContinuation = nil
                        continuation.resume(returning: false)
                    }
                    if self.isConnected {
                        self.isConnected = false
                        self.onDisconnect?(
                            self.lastDisconnectReason,
                            ConnectionManager.describeError(error)
                        )
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
                        // A cancel we initiated is already tagged .userInitiated by disconnect().
                        let reason = self.lastDisconnectReason == .userInitiated
                            ? DisconnectReason.userInitiated
                            : .remoteDisconnect
                        self.onDisconnect?(reason, "transport reported disconnected")
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
                        self.lastDisconnectReason = .remoteDisconnect
                        self.onDisconnect?(.remoteDisconnect, "peer closed the stream (EOF)")
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
                        self.lastDisconnectReason = ConnectionManager.classifyError(error)
                        self.onDisconnect?(
                            self.lastDisconnectReason,
                            ConnectionManager.describeError(error)
                        )
                        self.onConnectionLost?()
                    }
                }
            }
        )
    }
}
