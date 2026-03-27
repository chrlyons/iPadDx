import Foundation
import Network
import SwiftUI

@MainActor
@Observable
class BonjourService {
    var discoveredPeers: [PeerDevice] = []
    var connectedPeer: PeerDevice?
    var isAdvertising: Bool = false
    var isBrowsing: Bool = false
    var statusMessage: String = "Idle"
    var localRole: DeviceRole = .none
    var remoteTestInProgress: Bool = false
    var onReportReceived: ((Data) -> Void)?

    var localDeviceName: String {
        // Use user-set name if available, otherwise fall back to system name
        if let custom = UserDefaults.standard.string(forKey: "deviceName"), !custom.isEmpty {
            return custom
        }
        let systemName = UIDevice.current.name
        // iOS 16+ returns just "iPad" without the entitlement
        if systemName == "iPad" || systemName == "iPhone" {
            return "\(systemName)-\(deviceID.uuidString.prefix(4))"
        }
        return systemName
    }

    private var listener: NWListener?
    private var browser: NWBrowser?
    private var connectionManager: ConnectionManager?
    private var diagnosticEngine: DiagnosticEngine?
    private let serviceType = "_ipadconn._tcp"
    private let deviceID: UUID = {
        // Persist a stable device ID so the name suffix stays the same
        if let stored = UserDefaults.standard.string(forKey: "stableDeviceID"),
           let uuid = UUID(uuidString: stored)
        {
            return uuid
        }
        let uuid = UUID()
        UserDefaults.standard.set(uuid.uuidString, forKey: "stableDeviceID")
        return uuid
    }()

    var engine: DiagnosticEngine? {
        diagnosticEngine
    }

    var activeConnectionManager: ConnectionManager? {
        connectionManager
    }

    // MARK: - Advertising

    func startAdvertising() {
        guard !isAdvertising else { return }

        do {
            let params = NWParameters.tcp
            params.includePeerToPeer = true
            let listener = try NWListener(using: params)
            listener.service = NWListener.Service(
                name: localDeviceName,
                type: serviceType
            )

            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.statusMessage = "Advertising on port \(listener.port?.rawValue ?? 0)"
                        self.isAdvertising = true
                    case let .failed(error):
                        self.statusMessage = "Listener failed: \(error.localizedDescription)"
                        self.isAdvertising = false
                    case .cancelled:
                        self.isAdvertising = false
                    default:
                        break
                    }
                }
            }

            listener.newConnectionHandler = { [weak self] conn in
                Task { @MainActor in
                    self?.handleIncomingConnection(conn)
                }
            }

            listener.start(queue: .main)
            self.listener = listener
        } catch {
            statusMessage = "Failed to create listener: \(error.localizedDescription)"
        }
    }

    func stopAdvertising() {
        listener?.cancel()
        listener = nil
        isAdvertising = false
        statusMessage = "Stopped advertising"
    }

    // MARK: - Browsing

    func startBrowsing() {
        guard !isBrowsing else { return }

        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: params)

        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.isBrowsing = true
                    self.statusMessage = "Browsing for peers..."
                case let .failed(error):
                    self.statusMessage = "Browser failed: \(error.localizedDescription)"
                    self.isBrowsing = false
                default:
                    break
                }
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                self?.handleBrowseResults(results)
            }
        }

        browser.start(queue: .main)
        self.browser = browser
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
        isBrowsing = false
        discoveredPeers.removeAll()
    }

    // MARK: - Connection

    func connectToPeer(_ peer: PeerDevice) {
        guard connectedPeer == nil else {
            statusMessage = "Already connected to a peer"
            return
        }

        peer.connectionState = .connecting
        statusMessage = "Connecting to \(peer.name)..."

        let manager = ConnectionManager()
        manager.onConnectionLost = { [weak self] in
            self?.handleConnectionLost()
        }
        connectionManager = manager

        let engine = DiagnosticEngine(connectionManager: manager, metrics: peer.metrics)
        engine.peer = peer
        engine.onPeerNameUpdated = { [weak self] name in
            self?.statusMessage = "Connected to \(name) (Controller)"
        }
        engine.onTestSuiteStatus = { [weak self] msg in
            if case let .testSuiteStatus(running, _) = msg {
                self?.remoteTestInProgress = running
            }
        }
        engine.onReportReceived = { [weak self] data in
            self?.onReportReceived?(data)
        }
        engine.onRemoteDisconnect = { [weak self] in
            self?.handleRemoteDisconnect()
        }
        diagnosticEngine = engine

        manager.connect(to: peer.endpoint) { [weak self] data in
            Task { @MainActor in
                self?.diagnosticEngine?.handleMessage(data)
            }
        }

        // Monitor connection state
        Task {
            // Poll for connection ready state
            for _ in 0 ..< 100 {
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                if manager.isConnected {
                    peer.connectionState = .connected
                    peer.role = .responder // remote is responder
                    localRole = .controller // we initiated, we're the controller
                    connectedPeer = peer
                    statusMessage = "Connected to \(peer.name) (Controller)"
                    engine.start()
                    return
                }
            }
            peer.connectionState = .failed
            statusMessage = "Connection to \(peer.name) timed out"
        }
    }

    func sendReport(_ reportData: Data) {
        connectionManager?.send(.reportSync(reportJSON: reportData))
    }

    func disconnect() {
        guard let manager = connectionManager else { return }
        // Send disconnect message then delay TCP cancel so it can flush
        manager.send(.disconnect)
        let engine = diagnosticEngine

        // Clear all state and callbacks immediately
        diagnosticEngine = nil
        connectionManager = nil
        connectedPeer?.connectionState = .disconnected
        connectedPeer = nil
        localRole = .none
        remoteTestInProgress = false
        statusMessage = "Disconnected"

        engine?.onRemoteDisconnect = nil
        engine?.onTestSuiteStatus = nil
        engine?.onReportReceived = nil
        engine?.stop()
        manager.onConnectionLost = nil

        // Delay TCP cancel so .disconnect message flushes
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            manager.disconnect()
        }
    }

    func handleRemoteDisconnect() {
        cleanUp(status: "Remote device disconnected")
    }

    func handleConnectionLost() {
        cleanUp(status: "Connection lost")
    }

    private func cleanUp(status: String) {
        guard diagnosticEngine != nil || connectionManager != nil else { return }

        let engine = diagnosticEngine
        let manager = connectionManager

        // Clear all references first so callbacks can't re-trigger
        diagnosticEngine = nil
        connectionManager = nil
        connectedPeer?.connectionState = .disconnected
        connectedPeer = nil
        localRole = .none
        remoteTestInProgress = false
        statusMessage = status

        // Now safely tear down the old objects
        engine?.onRemoteDisconnect = nil
        engine?.onTestSuiteStatus = nil
        engine?.onReportReceived = nil
        engine?.stop()
        manager?.onConnectionLost = nil
        manager?.disconnect()
    }

    func startAll() {
        startAdvertising()
        startBrowsing()
    }

    func stopAll() {
        disconnect()
        stopBrowsing()
        stopAdvertising()
        statusMessage = "Idle"
    }

    // MARK: - Private

    private func handleBrowseResults(_ results: Set<NWBrowser.Result>) {
        var newPeers: [PeerDevice] = []
        for result in results {
            if case let .service(name, _, _, _) = result.endpoint {
                // Skip our own service
                if name == localDeviceName { continue }
                let peer = PeerDevice(name: name, endpoint: result.endpoint)
                // Preserve state if we already knew about this peer
                if let existing = discoveredPeers.first(where: { $0.name == name }) {
                    peer.connectionState = existing.connectionState
                    peer.metrics = existing.metrics
                }
                newPeers.append(peer)
            }
        }
        discoveredPeers = newPeers
    }

    private func handleIncomingConnection(_ conn: NWConnection) {
        guard connectedPeer == nil else {
            conn.cancel()
            return
        }

        // For incoming connections, the endpoint is usually an address, not a service name.
        // We use "Nearby Device" as placeholder — it updates when peerInfo arrives.
        let initialName: String = if case let .service(name, _, _, _) = conn.endpoint {
            name
        } else {
            "Nearby Device"
        }

        let peer = PeerDevice(name: initialName, endpoint: conn.endpoint)
        peer.connectionState = .connecting
        statusMessage = "Incoming connection..."

        let manager = ConnectionManager()
        manager.onConnectionLost = { [weak self] in
            self?.handleConnectionLost()
        }
        connectionManager = manager

        let engine = DiagnosticEngine(connectionManager: manager, metrics: peer.metrics)
        engine.peer = peer
        engine.onPeerNameUpdated = { [weak self] name in
            self?.statusMessage = "Connected to \(name) (Responder)"
        }
        engine.onTestSuiteStatus = { [weak self] msg in
            if case let .testSuiteStatus(running, phase) = msg {
                self?.remoteTestInProgress = running
                if running {
                    self?.statusMessage = "Test running: \(phase)"
                } else {
                    if let peerName = self?.connectedPeer?.name {
                        self?.statusMessage = "Connected to \(peerName) (Responder)"
                    }
                }
            }
        }
        engine.onReportReceived = { [weak self] data in
            self?.onReportReceived?(data)
        }
        engine.onRemoteDisconnect = { [weak self] in
            self?.handleRemoteDisconnect()
        }
        diagnosticEngine = engine

        manager.accept(conn) { [weak self] data in
            Task { @MainActor in
                self?.diagnosticEngine?.handleMessage(data)
            }
        }

        Task {
            for _ in 0 ..< 100 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if manager.isConnected {
                    peer.connectionState = .connected
                    peer.role = .controller // remote is controller
                    localRole = .responder // we accepted, we're the responder
                    connectedPeer = peer
                    statusMessage = "Connected to \(peer.name) (Responder)"
                    engine.start()
                    return
                }
            }
            peer.connectionState = .failed
            statusMessage = "Incoming connection timed out"
        }
    }
}
