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
    var appMode: AppMode = .standalone
    var conductorService: ConductorService?
    var agentService: AgentService?
    private var browseRefreshTimer: Timer?
    private var reverseTestEngines: [DiagnosticEngine] = []

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
            let params = ConnectionSecurity.tlsParameters(peerToPeer: true)
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
                        AppLog("Advertising on port \(listener.port?.rawValue ?? 0)", category: "Bonjour")
                    case let .failed(error):
                        self.statusMessage = "Listener failed: \(error.localizedDescription)"
                        self.isAdvertising = false
                        AppLog("Listener failed: \(error.localizedDescription)", level: .error, category: "Bonjour")
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

    func restartBrowsing() {
        browser?.cancel()
        browser = nil
        isBrowsing = false
        discoveredPeers.removeAll()
        startBrowsing()
    }

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
                    AppLog("Browsing started", category: "Bonjour")
                case let .failed(error):
                    self.statusMessage = "Browser failed: \(error.localizedDescription)"
                    self.isBrowsing = false
                    AppLog("Browser failed: \(error.localizedDescription)", level: .error, category: "Bonjour")
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
        AppLog("Connecting to \(peer.name)", category: "Bonjour")

        let manager = ConnectionManager(label: "standalone->\(peer.name)")
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
        engine.onOrchestration = { [weak self, weak manager] message in
            if case let .roleAssignment(role) = message, role == "agent", let manager {
                self?.enterAgentMode(conductorName: peer.name, conductorConnection: manager)
            }
            self?.agentService?.handleOrchestration(message)
        }
        diagnosticEngine = engine

        manager.connect(to: peer.endpoint) { [weak self] data in
            Task { @MainActor in
                self?.diagnosticEngine?.handleMessage(data)
            }
        }

        // Wait for connection
        Task {
            let ready = await manager.waitForReady(timeout: 15)
            guard ready else {
                peer.connectionState = .failed
                statusMessage = "Connection to \(peer.name) timed out"
                return
            }
            peer.connectionState = .connected
            peer.role = .responder // remote is responder
            localRole = .controller // we initiated, we're the controller
            connectedPeer = peer
            statusMessage = "Connected to \(peer.name) (Controller)"
            engine.start()
        }
    }

    func sendReport(_ reportData: Data) {
        connectionManager?.send(.reportSync(reportJSON: reportData))
    }

    func disconnect() {
        guard let manager = connectionManager else { return }
        let engine = diagnosticEngine

        // Send disconnect message
        manager.send(.disconnect)

        // Clear all state and callbacks immediately so UI updates
        diagnosticEngine = nil
        connectionManager = nil
        connectedPeer?.connectionState = .disconnected
        connectedPeer = nil
        localRole = .none
        remoteTestInProgress = false
        statusMessage = "Disconnected"

        // Null callbacks so they can't re-trigger
        engine?.onRemoteDisconnect = nil
        engine?.onTestSuiteStatus = nil
        engine?.onReportReceived = nil
        engine?.onOrchestration = nil
        manager.onConnectionLost = nil

        // Delay teardown so .disconnect message flushes
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            engine?.stop()
            manager.disconnect()
        }
    }

    // MARK: - Conductor Mode

    func enableConductorMode() {
        guard appMode == .standalone else { return }
        // Disconnect any standalone connection first
        if connectedPeer != nil { disconnect() }
        appMode = .conductor
        let cs = ConductorService()
        cs.conductorBonjourName = localDeviceName
        conductorService = cs
        statusMessage = "Conductor Mode"
        UIApplication.shared.isIdleTimerDisabled = true
        // Restart browsing to clear stale mDNS entries
        restartBrowsing()
        // Periodically refresh browser to prune stale mDNS cache
        browseRefreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.restartBrowsing()
            }
        }
    }

    func disableConductorMode() {
        browseRefreshTimer?.invalidate()
        browseRefreshTimer = nil
        let agentCount = conductorService?.fleet.count ?? 0
        AppLog("Disabling conductor mode, disconnecting \(agentCount) agents", category: "Bonjour")
        for engine in reverseTestEngines {
            engine.stop()
        }
        reverseTestEngines.removeAll()
        conductorService?.disconnectAll()
        // Keep reference alive until disconnect messages flush
        let cs = conductorService
        conductorService = nil
        appMode = .standalone
        statusMessage = "Standalone Mode"
        UIApplication.shared.isIdleTimerDisabled = false
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            _ = cs // prevent premature dealloc
        }
    }

    func connectAgentFromConductor(_ peer: PeerDevice) {
        conductorService?.connectToDevice(peer)
    }

    // MARK: - Agent Mode

    func enterAgentMode(conductorName: String, conductorConnection: ConnectionManager) {
        appMode = .agent
        UIApplication.shared.isIdleTimerDisabled = true

        // Stop the standalone ping loop but keep the engine alive for message routing
        diagnosticEngine?.stop() // stops ping timer only

        // Rewire callbacks for agent mode
        diagnosticEngine?.onPeerNameUpdated = { [weak self] name in
            self?.agentService?.conductorName = name
            self?.statusMessage = "Agent — Connected to \(name)"
        }
        diagnosticEngine?.onTestSuiteStatus = nil
        connectionManager?.onConnectionLost = nil

        // Clear standalone UI state
        connectedPeer = nil
        localRole = .none
        remoteTestInProgress = false

        // Set up agent service using the existing connection
        let agent = AgentService()
        agent.configure(conductorConnection: conductorConnection, conductorName: conductorName)
        agentService = agent
        statusMessage = "Agent — Connected to \(conductorName)"
    }

    func leaveAgentMode() {
        AppLog("Leaving agent mode", category: "Bonjour")
        agentService?.reset()
        agentService = nil

        // Clean up the underlying conductor connection
        let engine = diagnosticEngine
        let manager = connectionManager
        diagnosticEngine = nil
        connectionManager = nil
        engine?.onRemoteDisconnect = nil
        engine?.onOrchestration = nil
        engine?.stop()
        manager?.onConnectionLost = nil
        manager?.disconnect()

        appMode = .standalone
        statusMessage = "Standalone Mode"
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: - Disconnect Handlers

    func handleRemoteDisconnect() {
        guard appMode == .standalone else {
            // In agent mode, a disconnect from conductor means leave agent mode
            if appMode == .agent {
                leaveAgentMode()
            }
            return
        }
        cleanUp(status: "Remote device disconnected")
    }

    func handleConnectionLost() {
        if appMode == .agent {
            // Conductor connection dropped — leave agent mode
            AppLog("Conductor connection lost, leaving agent mode", level: .warning, category: "Bonjour")
            leaveAgentMode()
            return
        }
        // Don't clean up if we're in conductor mode — the connection
        // is managed by ConductorService, not BonjourService
        guard appMode == .standalone else { return }
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
        engine?.onOrchestration = nil
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
                peer.bonjourName = name
                // Preserve state if we already knew about this peer
                if let existing = discoveredPeers.first(where: { $0.bonjourName == name || $0.name == name }) {
                    peer.connectionState = existing.connectionState
                    peer.metrics = existing.metrics
                    peer.bonjourName = existing.bonjourName
                }
                newPeers.append(peer)
            }
        }
        let added = newPeers.filter { np in !discoveredPeers.contains { $0.name == np.name } }
        let removed = discoveredPeers.filter { op in !newPeers.contains { $0.name == op.name } }
        for p in added {
            AppLog("Discovered: \(p.name)", category: "Bonjour")
        }
        for p in removed {
            AppLog("Lost: \(p.name)", category: "Bonjour")
        }
        discoveredPeers = newPeers
    }

    private func handleIncomingConnection(_ conn: NWConnection) {
        // In agent mode, ALL incoming connections are test partner connections
        if appMode == .agent, let agent = agentService {
            agent.acceptTestPartnerConnection(conn)
            return
        }
        // In conductor mode, accept connections for reverse tests
        // (agent connecting back to test the conductor)
        if appMode == .conductor {
            // Set up a temporary connection for the test
            let manager = ConnectionManager(label: "conductor-reverse-test")
            let metrics = DiagnosticMetrics()
            let engine = DiagnosticEngine(connectionManager: manager, metrics: metrics)
            reverseTestEngines.append(engine)
            manager.accept(conn) { data in
                Task { @MainActor in
                    engine.handleMessage(data)
                }
            }
            manager.onConnectionLost = { [weak self, weak engine] in
                Task { @MainActor in
                    engine?.stop()
                    if let engine {
                        self?.reverseTestEngines.removeAll { $0 === engine }
                    }
                }
            }
            Task {
                let ready = await manager.waitForReady(timeout: 15)
                if ready { engine.start() }
            }
            return
        }
        // Reject if we already have a connection or are setting one up.
        // Network.framework may resolve a Bonjour name to multiple addresses
        // and connect via each — the listener accepts them all. Only keep the first.
        guard connectedPeer == nil, connectionManager == nil else {
            AppLog(
                "Rejecting duplicate incoming connection (peer=\(connectedPeer != nil), mgr=\(connectionManager != nil))",
                category: "Bonjour"
            )
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

        let manager = ConnectionManager(label: "incoming-\(initialName)")
        manager.onConnectionLost = { [weak self] in
            self?.handleConnectionLost()
        }
        connectionManager = manager

        let engine = DiagnosticEngine(connectionManager: manager, metrics: peer.metrics)
        engine.peer = peer
        engine.onPeerNameUpdated = { [weak self, weak peer] name in
            // Always store the resolved name on the peer object
            peer?.name = name
            if self?.appMode == .agent {
                self?.agentService?.conductorName = name
                self?.statusMessage = "Agent — Connected to \(name)"
            } else {
                self?.statusMessage = "Connected to \(name) (Responder)"
            }
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
        engine.onOrchestration = { [weak self, weak peer, weak manager] message in
            if case let .roleAssignment(role) = message, role == "agent", let manager {
                let name = peer?.name ?? "Conductor"
                self?.enterAgentMode(conductorName: name, conductorConnection: manager)
            }
            self?.agentService?.handleOrchestration(message)
        }
        diagnosticEngine = engine

        manager.accept(conn) { [weak self] data in
            Task { @MainActor in
                self?.diagnosticEngine?.handleMessage(data)
            }
        }

        Task {
            let ready = await manager.waitForReady(timeout: 15)
            guard ready else {
                guard appMode == .standalone else { return }
                peer.connectionState = .failed
                statusMessage = "Incoming connection timed out"
                return
            }

            // Send peer info immediately so the remote side gets our chip/model
            engine.sendPeerInfo()

            // Wait briefly for a potential roleAssignment from a conductor.
            // This prevents the standalone dashboard from flashing before
            // the device transitions to agent mode.
            try? await Task.sleep(nanoseconds: 500_000_000)

            // If we transitioned to agent mode during the wait, we're done —
            // peer info was already sent above
            guard appMode == .standalone else { return }

            peer.connectionState = .connected
            peer.role = .controller // remote is controller
            localRole = .responder // we accepted, we're the responder
            connectedPeer = peer
            statusMessage = "Connected to \(peer.name) (Responder)"
            engine.start()
        }
    }
}
