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
    var testQueue: [TestPair] = []
    var queueStatus: QueueStatus = .idle
    var completedCount: Int = 0
    var completedReports: [TestReport] = []
    var failedPairs: [TestPair] = []
    var runningPairs: [String] = []
    var eventLog: [ConductorEvent] = []
    private var cancelRequested = false
    private var activeTasks: [UUID: Task<Void, Never>] = [:]

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
        // Check if already in fleet (connected or connecting)
        guard !fleet.contains(where: { $0.peer.name == peer.name }) else { return }

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
        testQueue.append(pair)
    }

    func removePair(_ pair: TestPair) {
        testQueue.removeAll { $0.id == pair.id }
    }

    func generateAllPairs() {
        testQueue.removeAll()
        var allPeers = connectedAgents.map(\.peer)
        if let sp = selfPeer {
            allPeers.insert(sp, at: 0)
        }
        for i in 0 ..< allPeers.count {
            for j in 0 ..< allPeers.count where i != j {
                testQueue.append(TestPair(deviceA: allPeers[i], deviceB: allPeers[j]))
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
        failedPairs.removeAll()
        completedCount = 0
        runningPairs.removeAll()

        // Process queue — launch pairs in parallel when devices are available
        var remaining = testQueue
        activeTasks.removeAll()

        while !remaining.isEmpty || !activeTasks.isEmpty {
            // Check for cancellation
            if cancelRequested {
                log(
                    "Cancelling \(remaining.count) remaining pairs, waiting for \(activeTasks.count) active",
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
            // Prune pairs where a device has gone offline
            let deadPairs = remaining.filter { pair in
                let isSelfA = pair.deviceA.id == selfDeviceID
                let isSelfB = pair.deviceB.id == selfDeviceID
                if !isSelfA, fleet.first(where: { $0.peer.id == pair.deviceA.id }) == nil { return true }
                if !isSelfB, fleet.first(where: { $0.peer.id == pair.deviceB.id }) == nil { return true }
                return false
            }
            for pair in deadPairs {
                remaining.removeAll { $0.id == pair.id }
                completedCount += 1
                log("Skipped \(pair.label) — device offline", level: .warning)
            }

            // Find pairs where both devices are idle
            var launched = false
            for (index, pair) in remaining.enumerated() {
                let isSelfA = pair.deviceA.id == selfDeviceID
                let isSelfB = pair.deviceB.id == selfDeviceID

                let devicesAvailable: Bool
                if isSelfA || isSelfB {
                    let agentPeer = isSelfA ? pair.deviceB : pair.deviceA
                    let conn = fleet.first { $0.peer.id == agentPeer.id }
                    devicesAvailable = !selfBusy && conn?.agentStatus == .idle
                } else {
                    let connA = fleet.first { $0.peer.id == pair.deviceA.id }
                    let connB = fleet.first { $0.peer.id == pair.deviceB.id }
                    devicesAvailable = connA?.agentStatus == .idle && connB?.agentStatus == .idle
                }

                if devicesAvailable {
                    let pair = remaining.remove(at: index)
                    runningPairs.append(pair.label)

                    // Mark devices as busy BEFORE launching the task so the
                    // scheduler won't double-book them on the next iteration
                    let isSelfA2 = pair.deviceA.id == selfDeviceID
                    let isSelfB2 = pair.deviceB.id == selfDeviceID
                    if isSelfA2 || isSelfB2 {
                        selfBusy = true
                        let agentPeer2 = isSelfA2 ? pair.deviceB : pair.deviceA
                        if let conn2 = fleet.first(where: { $0.peer.id == agentPeer2.id }) {
                            conn2.agentStatus = .testing
                        }
                    } else {
                        if let cA = fleet.first(where: { $0.peer.id == pair.deviceA.id }) {
                            cA.agentStatus = .testing
                        }
                        if let cB = fleet.first(where: { $0.peer.id == pair.deviceB.id }) {
                            cB.agentStatus = .testing
                        }
                    }

                    let task = Task { [weak self] in
                        await self?.executePair(pair)
                        await MainActor.run {
                            self?.completedCount += 1
                            self?.runningPairs.removeAll { $0 == pair.label }
                            self?.queueStatus = .running(
                                pairIndex: self?.completedCount ?? 0,
                                total: total
                            )
                        }
                    }
                    activeTasks[pair.id] = task
                    launched = true
                    break // Re-evaluate from top after launching
                }
            }

            if !launched {
                // No pairs can launch right now — wait for an active one to finish
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

    // MARK: - Pair Execution

    private func executePair(_ pair: TestPair) async {
        let isSelfA = pair.deviceA.id == selfDeviceID
        let isSelfB = pair.deviceB.id == selfDeviceID

        if isSelfA || isSelfB {
            await executeSelfPair(pair, isSelfA: isSelfA)
        } else {
            await executeRemotePair(pair)
        }
    }

    private func executeSelfPair(_ pair: TestPair, isSelfA: Bool) async {
        let agentPeer = isSelfA ? pair.deviceB : pair.deviceA
        guard let conn = fleet.first(where: { $0.peer.id == agentPeer.id }) else {
            log("Self pair: \(agentPeer.name) not found in fleet", level: .error)
            return
        }

        let direction = isSelfA ? "Conductor → \(agentPeer.name)" : "\(agentPeer.name) → Conductor"
        log("Starting self pair: \(direction)")

        selfBusy = true
        conn.agentStatus = .testing
        conn.currentTestPartner = isSelfA ? "→ Conductor" : "Conductor →"

        if isSelfA {
            let runner = TestSuiteRunner(connectionManager: conn.connectionManager, metrics: conn.peer.metrics)
            if let engine = conn.diagnosticEngine { engine.testSuiteRunner = runner }
            let report = await runner.runFullSuite()
            if let report {
                completedReports.append(report)
                log("Self pair completed: \(direction) — \(report.results.overallGrade)", level: .success)
            } else {
                log("Self pair failed: \(direction) — no report generated", level: .error)
                failedPairs.append(pair)
            }
            if let engine = conn.diagnosticEngine { engine.testSuiteRunner = nil }
        } else {
            let config = TestSuiteConfig.default
            if let configData = try? JSONEncoder().encode(config) {
                conn.connectionManager.send(.orchestrateTest(
                    targetDeviceName: conductorBonjourName, configJSON: configData, role: "controller"
                ))
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                let completed = await waitForTestCompletion(connection: conn, timeout: 180)
                if completed {
                    log("Self pair completed: \(direction)", level: .success)
                } else {
                    let reason = conn.connectionManager.isConnected ? "timed out" : "device disconnected"
                    log("Self pair failed: \(direction) — \(reason)", level: .error)
                    failedPairs.append(pair)
                    if conn.connectionManager.isConnected {
                        conn.connectionManager.send(.orchestrationCancel)
                    }
                }
            }
        }

        // Settle delay — let agent clean up partner connections before reuse
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        if conn.connectionManager.isConnected {
            conn.agentStatus = .idle
            conn.currentTestPartner = nil
        }
        selfBusy = false
    }

    private func executeRemotePair(_ pair: TestPair) async {
        guard let connA = fleet.first(where: { $0.peer.id == pair.deviceA.id }),
              let connB = fleet.first(where: { $0.peer.id == pair.deviceB.id })
        else {
            log("Remote pair: devices not found in fleet", level: .error)
            return
        }

        let config = TestSuiteConfig.default
        guard let configData = try? JSONEncoder().encode(config) else { return }

        let label = "\(pair.deviceA.name) → \(pair.deviceB.name)"
        log("Starting remote pair: \(label)")

        connA.agentStatus = .testing
        connA.currentTestPartner = pair.deviceB.name
        connB.agentStatus = .testing
        connB.currentTestPartner = pair.deviceA.name

        // Use Bonjour names (not display names) for device discovery
        let nameA = pair.deviceA.bonjourName ?? pair.deviceA.name
        let nameB = pair.deviceB.bonjourName ?? pair.deviceB.name

        connB.connectionManager.send(.orchestrateTest(
            targetDeviceName: nameA, configJSON: configData, role: "responder"
        ))
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        connA.connectionManager.send(.orchestrateTest(
            targetDeviceName: nameB, configJSON: configData, role: "controller"
        ))

        try? await Task.sleep(nanoseconds: 2_000_000_000)
        let completed = await waitForTestCompletion(connection: connA, timeout: 180)

        if completed {
            log("Remote pair completed: \(label)", level: .success)
        } else {
            let reason = connA.connectionManager.isConnected ? "timed out" : "device disconnected"
            log("Remote pair failed: \(label) — \(reason)", level: .error)
            failedPairs.append(pair)
        }

        // Cancel responder if test failed
        if !completed {
            if connA.connectionManager.isConnected { connA.connectionManager.send(.orchestrationCancel) }
            if connB.connectionManager.isConnected { connB.connectionManager.send(.orchestrationCancel) }
        }

        // Wait for responder (connB) to also finish — it may still be responding
        // even after the controller reports done
        if connB.agentStatus == .testing {
            log("Waiting for responder \(pair.deviceB.name) to finish...", level: .info)
            for _ in 0 ..< 20 { // up to 10 seconds
                try? await Task.sleep(nanoseconds: 500_000_000)
                if connB.agentStatus != .testing { break }
                if !connB.connectionManager.isConnected { break }
            }
        }

        // Settle delay — let agent clean up partner connections before reuse
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        // Release both devices
        if connA.connectionManager.isConnected {
            connA.agentStatus = .idle
            connA.currentTestPartner = nil
        }
        if connB.connectionManager.isConnected {
            connB.agentStatus = .idle
            connB.currentTestPartner = nil
        }
    }

    // MARK: - Message Handling

    private func handleAgentMessage(_ message: DiagnosticMessage, from connection: DeviceConnection?) {
        guard let connection else { return }

        switch message {
        case let .orchestrationStatus(phase, detail):
            connection.testPhase = detail
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
                completedReports.append(report)
            }

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
        }
        return false
    }

    private func parseProgress(from detail: String) -> Double? {
        guard let range = detail.range(of: #"(\d+)%"#, options: .regularExpression),
              let pct = Int(detail[range].dropLast())
        else { return nil }
        return Double(pct) / 100
    }

    // MARK: - Event Log

    func log(_ message: String, level: ConductorEvent.EventLevel = .info) {
        let event = ConductorEvent(timestamp: Date(), level: level, message: message)
        eventLog.insert(event, at: 0)
        if eventLog.count > 100 { eventLog.removeLast() }
    }
}
