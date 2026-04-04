import Foundation
import Network

struct TestPair: Identifiable, Equatable {
    let id = UUID()
    let deviceA: PeerDevice
    let deviceB: PeerDevice

    var label: String {
        "\(deviceA.name) (\(deviceA.chipFamily ?? "?")) \u{2194} \(deviceB.name) (\(deviceB.chipFamily ?? "?"))"
    }

    static func == (lhs: TestPair, rhs: TestPair) -> Bool {
        lhs.id == rhs.id
    }
}

/// A single test run: a device pair + bridge transport.
/// When multiple bridges are selected, each pair generates one TestRun per bridge.
struct TestRun: Identifiable, Equatable {
    let id = UUID()
    let pair: TestPair
    let bridgeTransport: String

    var label: String {
        if bridgeTransport == "native" { return pair.label }
        return "\(pair.label) [\(bridgeTransport)]"
    }

    var deviceA: PeerDevice {
        pair.deviceA
    }

    var deviceB: PeerDevice {
        pair.deviceB
    }

    static func == (lhs: TestRun, rhs: TestRun) -> Bool {
        lhs.id == rhs.id
    }
}

enum QueueStatus: Equatable {
    case idle
    case running(pairIndex: Int, total: Int)
    case completed
    case failed(String)

    static func == (lhs: QueueStatus, rhs: QueueStatus) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.completed, .completed): true
        case let (.running(a1, a2), .running(b1, b2)): a1 == b1 && a2 == b2
        case let (.failed(a), .failed(b)): a == b
        default: false
        }
    }
}

struct ConductorEvent: Identifiable {
    let id = UUID()
    let timestamp: Date
    let level: EventLevel
    let message: String

    enum EventLevel: String {
        case info = "Info"
        case warning = "Warning"
        case error = "Error"
        case success = "Success"
    }
}

@MainActor
@Observable
class ConductorService {
    var fleet: [DeviceConnection] = []
    var includeSelf: Bool = false
    var testQueue: [TestRun] = []
    var queueStatus: QueueStatus = .idle
    var completedCount: Int = 0
    var completedReports: [TestReport] = []
    var failedRuns: [TestRun] = []
    var runningPairs: [String] = []
    var eventLog: [ConductorEvent] = []
    private var cancelRequested = false
    private var activeTasks: [UUID: Task<Void, Never>] = [:]

    /// Selected bridge transports for queue generation.
    var selectedBridges: [String] = ["native"]

    private let serviceType = "_ipadconn._tcp"
    private var listener: NWListener?
    private var browser: NWBrowser?

    var connectedAgents: [DeviceConnection] {
        fleet.filter(\.connectionManager.isConnected)
    }

    var idleAgents: [DeviceConnection] {
        fleet.filter { $0.connectionManager.isConnected && $0.agentStatus == .idle }
    }

    var selfPeer: PeerDevice? {
        guard includeSelf else { return nil }
        let info = DeviceIdentifier.localDeviceInfo()
        let peer = PeerDevice(
            id: DeviceIdentifier.stableID,
            name: info.name,
            endpoint: .hostPort(host: .ipv4(.loopback), port: 0)
        )
        peer.chipFamily = DeviceIdentifier.chipFamily
        peer.model = info.model
        return peer
    }

    // MARK: - Fleet Management

    func connectToDevice(_ peer: PeerDevice) {
        // Check if already in fleet by ID or name (covers reconnects and multi-interface discovery)
        guard !fleet.contains(where: { $0.peer.id == peer.id || $0.peer.name == peer.name }) else { return }

        // Reset stale state from a previous failed attempt
        peer.connectionState = .connecting

        let manager = ConnectionManager(label: "conductor->\(peer.name)")
        let connection = DeviceConnection(peer: peer, connectionManager: manager)

        let engine = DiagnosticEngine(connectionManager: manager, metrics: peer.metrics)
        engine.peer = peer
        engine.onPeerNameUpdated = { [weak peer] name in
            peer?.name = name
        }
        engine.onOrchestration = { [weak self, weak connection] message in
            self?.handleAgentMessage(message, from: connection)
        }
        engine.onRemoteDisconnect = { [weak self, weak connection] in
            if let connection {
                self?.removeFromFleet(connection)
            }
        }
        connection.diagnosticEngine = engine

        manager.onConnectionLost = { [weak self, weak connection] in
            if let connection {
                self?.removeFromFleet(connection)
            }
        }

        manager.connect(to: peer.endpoint) { data in
            Task { @MainActor in
                engine.handleMessage(data)
            }
        }

        fleet.append(connection)

        // Wait for connection then assign agent role, with one retry
        Task {
            var ready = await manager.waitForReady(timeout: 20)
            if !ready {
                // Retry once — the first attempt may have been congested
                log("Retrying connection to \(peer.name)...", level: .warning)
                manager.disconnect()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                manager.connect(to: peer.endpoint) { data in
                    Task { @MainActor in
                        engine.handleMessage(data)
                    }
                }
                ready = await manager.waitForReady(timeout: 20)
            }
            guard ready else {
                peer.connectionState = .failed
                log("Failed to connect to \(peer.name)", level: .error)
                removeFromFleet(connection)
                return
            }
            peer.connectionState = .connected
            engine.start()
            manager.send(.roleAssignment(role: "agent"))
            connection.agentStatus = .idle
            log("Connected to \(peer.name)", level: .success)
        }
    }

    func disconnectDevice(_ connection: DeviceConnection) {
        connection.connectionManager.send(.disconnect)
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            connection.diagnosticEngine?.stop()
            connection.connectionManager.disconnect()
        }
        removeFromFleet(connection)
    }

    func disconnectAll() {
        for connection in fleet {
            connection.connectionManager.send(.disconnect)
            connection.diagnosticEngine?.stop()
        }
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            for connection in fleet {
                connection.connectionManager.disconnect()
            }
            fleet.removeAll()
        }
    }

    private func removeFromFleet(_ connection: DeviceConnection) {
        // Mark as failed so any waitForTestCompletion exits immediately
        if connection.agentStatus == .testing || connection.agentStatus == .connecting {
            connection.agentStatus = .failed
            connection.testPhase = "Device disconnected"
            log("\(connection.peer.name) disconnected during test", level: .error)
        }
        connection.diagnosticEngine?.onOrchestration = nil
        connection.diagnosticEngine?.onRemoteDisconnect = nil
        connection.connectionManager.onConnectionLost = nil
        connection.diagnosticEngine?.stop()
        connection.connectionManager.disconnect()
        fleet.removeAll { $0.id == connection.id }
    }

    // MARK: - Test Queue

    func addPair(_ deviceA: PeerDevice, _ deviceB: PeerDevice) {
        let pair = TestPair(deviceA: deviceA, deviceB: deviceB)
        for bridge in selectedBridges {
            testQueue.append(TestRun(pair: pair, bridgeTransport: bridge))
        }
    }

    func removeRun(_ run: TestRun) {
        testQueue.removeAll { $0.id == run.id }
    }

    func generateAllPairs() {
        testQueue.removeAll()
        var allPeers = connectedAgents.map(\.peer)
        if let sp = selfPeer {
            allPeers.insert(sp, at: 0)
        }
        // Generate all permutations for each selected bridge.
        // Interleave bridges to avoid running same pair back-to-back with different bridges.
        var pairs: [TestPair] = []
        for i in 0 ..< allPeers.count {
            for j in 0 ..< allPeers.count where i != j {
                pairs.append(TestPair(deviceA: allPeers[i], deviceB: allPeers[j]))
            }
        }
        // Interleave bridges across pairs to prevent thermal throttling:
        // A→B [native], C→A [native], A→B [cordova], B→C [native], C→A [cordova], ...
        if selectedBridges.count <= 1 {
            for pair in pairs {
                testQueue.append(TestRun(pair: pair, bridgeTransport: selectedBridges.first ?? "native"))
            }
        } else {
            // Build per-bridge queues, then interleave
            var bridgeQueues: [[TestRun]] = selectedBridges.map { bridge in
                pairs.map { TestRun(pair: $0, bridgeTransport: bridge) }
            }
            while bridgeQueues.contains(where: { !$0.isEmpty }) {
                for i in 0 ..< bridgeQueues.count {
                    if !bridgeQueues[i].isEmpty {
                        testQueue.append(bridgeQueues[i].removeFirst())
                    }
                }
            }
        }
    }

    private let selfDeviceID = DeviceIdentifier.stableID
    var conductorBonjourName: String = ""
    private var selfBusy = false

    func cancelQueue() {
        guard queueStatus != .idle else { return }
        cancelRequested = true
        log("Queue cancellation requested", level: .warning)

        // Cancel all active tasks
        for (_, task) in activeTasks {
            task.cancel()
        }

        // Send cancel to all agents that are currently testing
        for conn in fleet where conn.agentStatus == .testing {
            conn.connectionManager.send(.orchestrationCancel)
            conn.agentStatus = .idle
            conn.currentTestPartner = nil
            conn.testProgress = 0
            conn.testPhase = ""
        }
        selfBusy = false
    }

    func runQueue(reportStore _: ReportStore) async {
        guard !testQueue.isEmpty else { return }
        cancelRequested = false
        let total = testQueue.count
        queueStatus = .running(pairIndex: 0, total: total)
        completedReports.removeAll()
        failedRuns.removeAll()
        completedCount = 0
        runningPairs.removeAll()

        // Process queue — launch runs in parallel when devices are available
        var remaining = testQueue
        activeTasks.removeAll()

        while !remaining.isEmpty || !activeTasks.isEmpty {
            // Check for cancellation
            if cancelRequested {
                log(
                    "Cancelling \(remaining.count) remaining runs, waiting for \(activeTasks.count) active",
                    level: .warning
                )
                remaining.removeAll()
                for (_, task) in activeTasks {
                    task.cancel()
                }
                for (_, task) in activeTasks {
                    await task.value
                }
                activeTasks.removeAll()
                break
            }
            // Prune runs where a device has gone offline
            let deadRuns = remaining.filter { run in
                let isSelfA = run.deviceA.id == selfDeviceID
                let isSelfB = run.deviceB.id == selfDeviceID
                if !isSelfA, fleet.first(where: { $0.peer.id == run.deviceA.id }) == nil { return true }
                if !isSelfB, fleet.first(where: { $0.peer.id == run.deviceB.id }) == nil { return true }
                return false
            }
            for run in deadRuns {
                remaining.removeAll { $0.id == run.id }
                completedCount += 1
                log("Skipped \(run.label) — device offline", level: .warning)
            }

            // Find runs where both devices are idle
            var launched = false
            for (index, run) in remaining.enumerated() {
                let isSelfA = run.deviceA.id == selfDeviceID
                let isSelfB = run.deviceB.id == selfDeviceID

                let devicesAvailable: Bool
                if isSelfA || isSelfB {
                    let agentPeer = isSelfA ? run.deviceB : run.deviceA
                    let conn = fleet.first { $0.peer.id == agentPeer.id }
                    devicesAvailable = !selfBusy && conn?.agentStatus == .idle
                } else {
                    let connA = fleet.first { $0.peer.id == run.deviceA.id }
                    let connB = fleet.first { $0.peer.id == run.deviceB.id }
                    devicesAvailable = connA?.agentStatus == .idle && connB?.agentStatus == .idle
                }

                if devicesAvailable {
                    let run = remaining.remove(at: index)
                    runningPairs.append(run.label)

                    // Mark devices as busy BEFORE launching the task
                    let isSelfA2 = run.deviceA.id == selfDeviceID
                    let isSelfB2 = run.deviceB.id == selfDeviceID
                    if isSelfA2 || isSelfB2 {
                        selfBusy = true
                        let agentPeer2 = isSelfA2 ? run.deviceB : run.deviceA
                        if let conn2 = fleet.first(where: { $0.peer.id == agentPeer2.id }) {
                            conn2.agentStatus = .testing
                            conn2.lastStatusUpdate = Date()
                        }
                    } else {
                        if let cA = fleet.first(where: { $0.peer.id == run.deviceA.id }) {
                            cA.agentStatus = .testing
                            cA.lastStatusUpdate = Date()
                        }
                        if let cB = fleet.first(where: { $0.peer.id == run.deviceB.id }) {
                            cB.agentStatus = .testing
                            cB.lastStatusUpdate = Date()
                        }
                    }

                    let task = Task { [weak self] in
                        await self?.executeRun(run)
                        await MainActor.run {
                            self?.completedCount += 1
                            self?.runningPairs.removeAll { $0 == run.label }
                            self?.queueStatus = .running(
                                pairIndex: self?.completedCount ?? 0,
                                total: total
                            )
                        }
                    }
                    activeTasks[run.id] = task
                    launched = true
                    break // Re-evaluate from top after launching
                }
            }

            if !launched {
                if let (id, task) = activeTasks.first {
                    await task.value
                    activeTasks.removeValue(forKey: id)
                } else {
                    break
                }
            }
        }

        // Wait for any remaining active tasks
        for (_, task) in activeTasks {
            await task.value
        }
        activeTasks.removeAll()

        // Reset all agent statuses
        for conn in fleet {
            conn.agentStatus = .idle
            conn.currentTestPartner = nil
            conn.testProgress = 0
            conn.testPhase = ""
        }
        selfBusy = false

        if cancelRequested {
            queueStatus = .idle
            log("Queue cancelled — \(completedCount)/\(total) completed", level: .warning)
        } else {
            queueStatus = .completed
        }
        runningPairs.removeAll()
        testQueue.removeAll()
        cancelRequested = false
    }

    // MARK: - Run Execution

    private func executeRun(_ run: TestRun) async {
        let isSelfA = run.deviceA.id == selfDeviceID
        let isSelfB = run.deviceB.id == selfDeviceID

        if isSelfA || isSelfB {
            await executeSelfRun(run, isSelfA: isSelfA)
        } else {
            await executeRemoteRun(run)
        }
    }

    private func executeSelfRun(_ run: TestRun, isSelfA: Bool) async {
        // Refuse to run if the bridge failed to initialize — results would be invalid
        if run.bridgeTransport != "native", !BridgeRegistry.isBridgeHealthy(run.bridgeTransport) {
            log("Bridge \(run.bridgeTransport) not healthy, skipping self run", level: .error)
            failedRuns.append(run)
            return
        }

        let agentPeer = isSelfA ? run.deviceB : run.deviceA
        guard let conn = fleet.first(where: { $0.peer.id == agentPeer.id }) else {
            log("Self run: \(agentPeer.name) not found in fleet", level: .error)
            return
        }

        let bridgeTag = run.bridgeTransport == "native" ? "" : " [\(run.bridgeTransport)]"
        let direction = isSelfA ? "Conductor → \(agentPeer.name)\(bridgeTag)" : "\(agentPeer.name) → Conductor\(bridgeTag)"
        log("Starting self run: \(direction)")

        selfBusy = true
        conn.agentStatus = .testing
        conn.lastStatusUpdate = Date()
        conn.currentTestPartner = isSelfA ? "→ Conductor" : "Conductor →"
        conn.testProgress = 0
        conn.testPhase = ""

        if isSelfA {
            let runner = TestSuiteRunner(connectionManager: conn.connectionManager, metrics: conn.peer.metrics)
            runner.bridgeTransportOverride = run.bridgeTransport
            if let engine = conn.diagnosticEngine { engine.testSuiteRunner = runner }
            let report = await runner.runFullSuite()
            if let report {
                // In self-run where conductor is sender (isSelfA):
                // localDevice = conductor (self), remoteDevice = the agent
                completedReports.append(patchDeviceInfo(in: report, controllerConn: nil, responderConn: conn))
                log("Self run completed: \(direction) — \(report.results.overallGrade)", level: .success)
            } else {
                log("Self run failed: \(direction) — no report generated", level: .error)
                failedRuns.append(run)
            }
            if let engine = conn.diagnosticEngine { engine.testSuiteRunner = nil }
        } else {
            let config = TestSuiteConfig.default
            if let configData = try? JSONEncoder().encode(config) {
                conn.connectionManager.send(.orchestrateTest(
                    targetDeviceName: conductorBonjourName, configJSON: configData,
                    role: "controller", bridgeTransport: run.bridgeTransport
                ))
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                let completed = await waitForTestCompletion(connection: conn, timeout: 180)
                if completed {
                    log("Self run completed: \(direction)", level: .success)
                } else {
                    let reason = conn.connectionManager.isConnected ? "timed out" : "device disconnected"
                    log("Self run failed: \(direction) — \(reason)", level: .error)
                    failedRuns.append(run)
                    if conn.connectionManager.isConnected {
                        conn.connectionManager.send(.orchestrationCancel)
                    }
                }
            }
        }

        // Settle delay
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        if conn.connectionManager.isConnected {
            conn.agentStatus = .idle
            conn.currentTestPartner = nil
            conn.testProgress = 0
            conn.testPhase = ""
        }
        selfBusy = false
    }

    private func executeRemoteRun(_ run: TestRun) async {
        guard let connA = fleet.first(where: { $0.peer.id == run.deviceA.id }),
              let connB = fleet.first(where: { $0.peer.id == run.deviceB.id })
        else {
            log("Remote run: devices not found in fleet", level: .error)
            return
        }

        let config = TestSuiteConfig.default
        guard let configData = try? JSONEncoder().encode(config) else { return }

        let bridgeTag = run.bridgeTransport == "native" ? "" : " [\(run.bridgeTransport)]"
        let label = "\(run.deviceA.name) → \(run.deviceB.name)\(bridgeTag)"
        log("Starting remote run: \(label)")

        connA.agentStatus = .testing
        connA.lastStatusUpdate = Date()
        connA.currentTestPartner = run.deviceB.name
        connA.testProgress = 0
        connA.testPhase = ""
        connB.agentStatus = .testing
        connB.lastStatusUpdate = Date()
        connB.currentTestPartner = run.deviceA.name
        connB.testProgress = 0
        connB.testPhase = ""

        // Use Bonjour names (not display names) for device discovery
        let nameA = run.deviceA.bonjourName ?? run.deviceA.name
        let nameB = run.deviceB.bonjourName ?? run.deviceB.name

        connB.connectionManager.send(.orchestrateTest(
            targetDeviceName: nameA, configJSON: configData,
            role: "responder", bridgeTransport: run.bridgeTransport
        ))
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        connA.connectionManager.send(.orchestrateTest(
            targetDeviceName: nameB, configJSON: configData,
            role: "controller", bridgeTransport: run.bridgeTransport
        ))

        try? await Task.sleep(nanoseconds: 2_000_000_000)
        let completed = await waitForTestCompletion(connection: connA, timeout: 180)

        if completed {
            log("Remote run completed: \(label)", level: .success)
        } else {
            let reason = connA.connectionManager.isConnected ? "timed out" : "device disconnected"
            log("Remote run failed: \(label) — \(reason)", level: .error)
            failedRuns.append(run)
        }

        if !completed {
            if connA.connectionManager.isConnected { connA.connectionManager.send(.orchestrationCancel) }
            if connB.connectionManager.isConnected { connB.connectionManager.send(.orchestrationCancel) }
        }

        // Wait for responder (connB) to finish
        if connB.agentStatus == .testing {
            log("Waiting for responder \(run.deviceB.name) to finish...", level: .info)
            for _ in 0 ..< 20 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if connB.agentStatus != .testing { break }
                if !connB.connectionManager.isConnected { break }
            }
        }

        // Settle delay
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        if connA.connectionManager.isConnected {
            connA.agentStatus = .idle
            connA.currentTestPartner = nil
            connA.testProgress = 0
            connA.testPhase = ""
        }
        if connB.connectionManager.isConnected {
            connB.agentStatus = .idle
            connB.currentTestPartner = nil
            connB.testProgress = 0
            connB.testPhase = ""
        }
    }

    // MARK: - Message Handling

    private func handleAgentMessage(_ message: DiagnosticMessage, from connection: DeviceConnection?) {
        guard let connection else { return }

        switch message {
        case let .orchestrationStatus(phase, detail):
            connection.testPhase = detail
            connection.lastStatusUpdate = Date()
            if phase == "failed" {
                log("\(connection.peer.name): \(detail)", level: .error)
            } else if phase == "completed" {
                log("\(connection.peer.name): \(detail)", level: .success)
            }
            if phase == "running", let pct = parseProgress(from: detail) {
                connection.testProgress = pct
            }
            if phase == "completed" || phase == "failed" {
                connection.agentStatus = phase == "completed" ? .completed : .failed
            }

        case let .orchestrationReport(reportJSON):
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let report = try? decoder.decode(TestReport.self, from: reportJSON) {
                // The controller agent sent this report. Its partner is the responder.
                let partnerName = connection.currentTestPartner
                let responderConn = fleet.first { $0.peer.name == partnerName }
                let patched = patchDeviceInfo(
                    in: report,
                    controllerConn: connection,
                    responderConn: responderConn
                )
                completedReports.append(patched)
            }

        case let .agentCapabilities(supportedBridges):
            connection.supportedBridges = supportedBridges
            log("\(connection.peer.name) supports bridges: \(supportedBridges.joined(separator: ", "))")

        default:
            break
        }
    }

    private func waitForTestCompletion(connection: DeviceConnection, timeout: Int) async -> Bool {
        for _ in 0 ..< (timeout * 2) {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if connection.agentStatus == .completed || connection.agentStatus == .failed {
                return connection.agentStatus == .completed
            }
            // Device disconnected — fail fast instead of waiting full timeout
            if !connection.connectionManager.isConnected {
                connection.agentStatus = .failed
                return false
            }
            // Detect stale agent — no status update for 30s while supposedly testing
            if connection.agentStatus == .testing,
               Date().timeIntervalSince(connection.lastStatusUpdate) > 30
            {
                log("\(connection.peer.name) unresponsive for 30s", level: .error)
                connection.agentStatus = .failed
                connection.testPhase = "Agent unresponsive"
                return false
            }
        }
        return false
    }

    private func parseProgress(from detail: String) -> Double? {
        guard let range = detail.range(of: #"(\d+)%"#, options: .regularExpression),
              let pct = Int(detail[range].dropLast())
        else { return nil }
        return Double(pct) / 100
    }

    // MARK: - Report Patching

    /// The controller agent builds its report from a fresh peer-to-peer connection whose
    /// .peerInfo() exchange may not complete in time (5s timeout). The conductor already
    /// has authoritative device info from its fleet connections, so patch any "Unknown"
    /// fields before storing the report.
    ///
    /// Uses orchestration context (which connection sent the report and who its partner was)
    /// rather than name matching, since the report's device names may themselves be "Unknown".
    private func patchDeviceInfo(
        in report: TestReport,
        controllerConn: DeviceConnection?,
        responderConn: DeviceConnection?
    ) -> TestReport {
        // report.localDevice = the controller agent (the one that ran the test suite)
        // report.remoteDevice = the responder agent (the peer it connected to)
        let patchedLocal = patchDevice(report.localDevice, from: controllerConn)
        let patchedRemote = patchDevice(report.remoteDevice, from: responderConn)

        guard patchedLocal != report.localDevice || patchedRemote != report.remoteDevice else {
            return report
        }

        return TestReport(
            id: report.id,
            date: report.date,
            localDevice: patchedLocal,
            remoteDevice: patchedRemote,
            results: report.results,
            durationSeconds: report.durationSeconds,
            errors: report.errors,
            skippedPhases: report.skippedPhases,
            bridgeTransport: report.bridgeTransport
        )
    }

    private func patchDevice(_ info: DeviceInfo, from conn: DeviceConnection?) -> DeviceInfo {
        guard let conn else { return info }
        let metrics = conn.peer.metrics
        let needsPatch = info.name == "Unknown" || info.model == "Unknown" || info.osVersion == "Unknown"
        guard needsPatch else { return info }

        return DeviceInfo(
            name: info.name != "Unknown" ? info.name : metrics.peerDeviceName ?? conn.peer.name,
            model: info.model != "Unknown" ? info.model : metrics.peerModel ?? conn.peer.model ?? "Unknown",
            modelNumber: !info.modelNumber.isEmpty ? info.modelNumber : metrics.peerModelNumber ?? "",
            osVersion: info.osVersion != "Unknown" ? info.osVersion : metrics.peerOSVersion ?? "Unknown"
        )
    }

    // MARK: - Event Log

    func log(_ message: String, level: ConductorEvent.EventLevel = .info) {
        let event = ConductorEvent(timestamp: Date(), level: level, message: message)
        eventLog.insert(event, at: 0)
        if eventLog.count > 100 { eventLog.removeLast() }
    }
}
