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

@MainActor
@Observable
class ConductorService {
    var fleet: [DeviceConnection] = []
    var testQueue: [TestPair] = []
    var queueStatus: QueueStatus = .idle
    var currentPairLabel: String = ""
    var completedReports: [TestReport] = []

    private let serviceType = "_ipadconn._tcp"
    private var listener: NWListener?
    private var browser: NWBrowser?

    var connectedAgents: [DeviceConnection] {
        fleet.filter(\.connectionManager.isConnected)
    }

    var idleAgents: [DeviceConnection] {
        fleet.filter { $0.connectionManager.isConnected && $0.agentStatus == .idle }
    }

    // MARK: - Fleet Management

    func connectToDevice(_ peer: PeerDevice) {
        // Check if already connected
        guard !fleet.contains(where: { $0.peer.name == peer.name }) else { return }

        let manager = ConnectionManager()
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

        // Wait for connection then assign agent role
        Task {
            for _ in 0 ..< 100 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if manager.isConnected {
                    peer.connectionState = .connected
                    engine.start()
                    // Assign agent role
                    manager.send(.roleAssignment(role: "agent"))
                    connection.agentStatus = .idle
                    return
                }
            }
            peer.connectionState = .failed
            removeFromFleet(connection)
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

    func generateAllPairs(includingSelf: PeerDevice? = nil) {
        testQueue.removeAll()
        var allPeers = connectedAgents.map(\.peer)
        if let selfPeer = includingSelf {
            allPeers.insert(selfPeer, at: 0)
        }
        // Generate both directions: A→B and B→A
        for i in 0 ..< allPeers.count {
            for j in 0 ..< allPeers.count where i != j {
                let pair = TestPair(deviceA: allPeers[i], deviceB: allPeers[j])
                testQueue.append(pair)
            }
        }
    }

    private let selfDeviceID = DeviceIdentifier.stableID
    var conductorBonjourName: String = ""

    func runQueue(reportStore _: ReportStore) async {
        guard !testQueue.isEmpty else { return }
        queueStatus = .running(pairIndex: 0, total: testQueue.count)
        completedReports.removeAll()

        for (index, pair) in testQueue.enumerated() {
            queueStatus = .running(pairIndex: index, total: testQueue.count)
            currentPairLabel = pair.label

            let isSelfA = pair.deviceA.id == selfDeviceID
            let isSelfB = pair.deviceB.id == selfDeviceID

            if isSelfA || isSelfB {
                // One side is the conductor
                let agentPeer = isSelfA ? pair.deviceB : pair.deviceA
                guard let conn = fleet.first(where: { $0.peer.id == agentPeer.id }),
                      conn.agentStatus == .idle
                else { continue }

                conn.agentStatus = .testing
                conn.currentTestPartner = isSelfA ? "Conductor → \(agentPeer.name)" : "\(agentPeer.name) → Conductor"

                if isSelfA {
                    // Conductor is sender — run test locally using agent's connection
                    let runner = TestSuiteRunner(
                        connectionManager: conn.connectionManager,
                        metrics: conn.peer.metrics
                    )
                    if let engine = conn.diagnosticEngine {
                        engine.testSuiteRunner = runner
                    }
                    let report = await runner.runFullSuite()
                    if let report {
                        completedReports.append(report)
                    }
                    if let engine = conn.diagnosticEngine {
                        engine.testSuiteRunner = nil
                    }
                } else {
                    // Agent is sender — tell agent to run the test back to conductor
                    // Agent connects to conductor's Bonjour name and runs as controller
                    let config = TestSuiteConfig.default
                    if let configData = try? JSONEncoder().encode(config) {
                        conn.connectionManager.send(.orchestrateTest(
                            targetDeviceName: conductorBonjourName,
                            configJSON: configData,
                            role: "controller"
                        ))
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        let completed = await waitForTestCompletion(connection: conn, timeout: 180)
                        if !completed {
                            conn.connectionManager.send(.orchestrationCancel)
                        }
                    }
                }

                conn.agentStatus = .idle
                conn.currentTestPartner = nil
            } else {
                // Both are remote agents — orchestrate
                guard let connA = fleet.first(where: { $0.peer.id == pair.deviceA.id }),
                      let connB = fleet.first(where: { $0.peer.id == pair.deviceB.id }),
                      connA.agentStatus == .idle, connB.agentStatus == .idle
                else { continue }

                let config = TestSuiteConfig.default
                guard let configData = try? JSONEncoder().encode(config) else { continue }

                connA.agentStatus = .testing
                connA.currentTestPartner = pair.deviceB.name
                connB.agentStatus = .testing
                connB.currentTestPartner = pair.deviceA.name

                // Tell B to prepare as responder first
                connB.connectionManager.send(.orchestrateTest(
                    targetDeviceName: pair.deviceA.name,
                    configJSON: configData,
                    role: "responder"
                ))
                // Small delay so B is ready before A connects
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                // Tell A to initiate as controller
                connA.connectionManager.send(.orchestrateTest(
                    targetDeviceName: pair.deviceB.name,
                    configJSON: configData,
                    role: "controller"
                ))

                try? await Task.sleep(nanoseconds: 2_000_000_000)
                let completed = await waitForTestCompletion(connection: connA, timeout: 180)

                connA.agentStatus = .idle
                connA.currentTestPartner = nil
                connB.agentStatus = .idle
                connB.currentTestPartner = nil

                if !completed {
                    connA.connectionManager.send(.orchestrationCancel)
                }
            }
        }

        queueStatus = .completed
        currentPairLabel = ""
        testQueue.removeAll()
    }

    // MARK: - Message Handling

    private func handleAgentMessage(_ message: DiagnosticMessage, from connection: DeviceConnection?) {
        guard let connection else { return }

        switch message {
        case let .orchestrationStatus(phase, detail):
            connection.testPhase = detail
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
        }
        return false
    }

    private func parseProgress(from detail: String) -> Double? {
        // Try to extract percentage from detail like "Latency Burst — 42%"
        guard let range = detail.range(of: #"(\d+)%"#, options: .regularExpression),
              let pct = Int(detail[range].dropLast())
        else { return nil }
        return Double(pct) / 100
    }
}
