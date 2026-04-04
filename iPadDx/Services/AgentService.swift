import Foundation
import Network
import UIKit

@MainActor
@Observable
class AgentService {
    var conductorName: String = ""
    var status: AgentStatus = .idle
    var testPartnerName: String = ""
    var testProgress: Double = 0
    var testPhase: String = ""
    var liveLatency: Double = 0

    private var conductorConnection: ConnectionManager?
    private var partnerConnection: ConnectionManager?
    private var partnerEngine: DiagnosticEngine?
    private var testRunner: TestSuiteRunner?
    private let serviceType = "_ipadconn._tcp"
    private var testGeneration: Int = 0
    private var activeBridgeTransport: String = "native"

    func configure(conductorConnection: ConnectionManager, conductorName: String) {
        self.conductorConnection = conductorConnection
        self.conductorName = conductorName
        status = .idle
    }

    func handleOrchestration(_ message: DiagnosticMessage) {
        switch message {
        case let .orchestrateTest(targetDeviceName, configJSON, role, bridgeTransport):
            let config = (try? JSONDecoder().decode(TestSuiteConfig.self, from: configJSON)) ?? .default
            if role == "responder" {
                // Clean up any previous partner connection
                partnerConnection?.onConnectionLost = nil
                partnerConnection?.disconnect()
                partnerConnection = nil
                // Prepare to accept incoming connection — don't initiate
                status = .connecting
                testPartnerName = targetDeviceName
                activeBridgeTransport = bridgeTransport
                sendStatus("preparing", detail: "Waiting for \(targetDeviceName) to connect")
            } else {
                // Controller — initiate connection and run tests
                Task {
                    await executeTest(targetName: targetDeviceName, config: config, bridgeTransport: bridgeTransport)
                }
            }

        case .orchestrationCancel:
            cancelTest()

        default:
            break
        }
    }

    func cancelTest() {
        testGeneration += 1 // invalidate any pending async work
        partnerEngine?.stop()
        partnerEngine = nil
        partnerConnection?.onConnectionLost = nil
        partnerConnection?.disconnect()
        partnerConnection = nil
        testRunner = nil
        status = .idle
        testPartnerName = ""
        testProgress = 0
        activeBridgeTransport = "native"
        sendStatus("cancelled", detail: "Test cancelled by conductor")
    }

    /// Accept an incoming connection from a test partner (another agent)
    func acceptTestPartnerConnection(_ conn: NWConnection) {
        // Reject if we're not expecting a partner connection
        if status != .connecting, status != .idle {
            AppLog("Rejecting partner connection — already \(status)", level: .warning, category: "Agent")
            conn.cancel()
            return
        }

        // Clean up any previous partner connection
        partnerEngine?.stop()
        partnerEngine = nil
        partnerConnection?.onConnectionLost = nil
        partnerConnection?.disconnect()
        partnerConnection = nil

        let manager = ConnectionManager(label: "agent-responder", bridgeTransport: activeBridgeTransport)
        partnerConnection = manager

        let metrics = DiagnosticMetrics()
        let engine = DiagnosticEngine(connectionManager: manager, metrics: metrics)
        partnerEngine = engine

        manager.accept(conn) { data in
            Task { @MainActor in
                engine.handleMessage(data)
            }
        }

        // When the partner disconnects, determine if it's normal completion or a real failure.
        // The controller disconnects after finishing the test — that's expected for responders.
        // Only report failure if we were still connecting (never got to test).
        manager.onConnectionLost = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let wasConnecting = self.status == .connecting
                self.partnerEngine?.stop()
                self.partnerEngine = nil
                self.partnerConnection = nil
                self.testPartnerName = ""
                self.testProgress = 0
                if wasConnecting {
                    // Never got to test — real failure
                    self.status = .failed
                    self.sendStatus("failed", detail: "Partner disconnected before test started")
                } else {
                    // Was testing — controller finished and disconnected (normal)
                    self.status = .idle
                    self.sendStatus("completed", detail: "Responder finished")
                }
            }
        }

        testGeneration += 1
        let myGeneration = testGeneration

        status = .connecting
        sendStatus("connecting", detail: "Handshaking with \(testPartnerName)")

        Task {
            let ready = await manager.waitForReady(timeout: 15)
            // If a cancel or new test arrived while waiting, bail out
            guard myGeneration == testGeneration else { return }
            guard ready else {
                partnerConnection?.disconnect()
                partnerConnection = nil
                status = .failed
                testPartnerName = ""
                sendStatus("failed", detail: "Partner connection timed out")
                return
            }
            status = .testing
            sendStatus("testing", detail: "Responding to \(testPartnerName)")
            engine.start()
        }
    }

    func reset() {
        cancelTest()
        conductorConnection = nil
        conductorName = ""
        status = .idle
    }

    // MARK: - Test Execution

    private func executeTest(targetName: String, config: TestSuiteConfig, bridgeTransport: String = "native") async {
        // Refuse to run if the bridge failed to initialize — results would be invalid
        if bridgeTransport != "native", !BridgeRegistry.isBridgeHealthy(bridgeTransport) {
            AppLog("Bridge \(bridgeTransport) not healthy, refusing test", level: .error, category: "Agent")
            sendStatus("failed", detail: "Bridge \(bridgeTransport) failed to initialize")
            return
        }

        testGeneration += 1
        let myGeneration = testGeneration

        testPartnerName = targetName
        status = .connecting

        sendStatus("connecting", detail: "Connecting to \(targetName)")

        // Connect directly using the Bonjour service name — no browse needed,
        // Network.framework resolves the name internally
        let endpoint = NWEndpoint.service(
            name: targetName, type: serviceType, domain: "local.", interface: nil
        )

        let manager = ConnectionManager(label: "agent-controller->\(targetName)", bridgeTransport: bridgeTransport)
        partnerConnection = manager

        let metrics = DiagnosticMetrics()
        let engine = DiagnosticEngine(connectionManager: manager, metrics: metrics)

        manager.connect(to: endpoint) { data in
            Task { @MainActor in
                engine.handleMessage(data)
            }
        }

        // Detect partner disconnect during test
        manager.onConnectionLost = { [weak self] in
            Task { @MainActor in
                guard let self, self.status == .testing else { return }
                self.partnerConnection = nil
                self.status = .failed
                self.testPartnerName = ""
                self.testProgress = 0
                self.sendStatus("failed", detail: "Partner disconnected during test")
            }
        }

        // Wait for connection
        let connected = await manager.waitForReady(timeout: 15)
        guard myGeneration == testGeneration else { return }

        guard connected else {
            status = .failed
            sendStatus("failed", detail: "Connection to \(targetName) timed out")
            partnerConnection = nil
            return
        }

        // Start engine and run tests
        engine.start()
        status = .testing
        sendStatus("running", detail: "Starting test suite")

        // Wait for peer info to arrive (up to 5 seconds, check every 200ms)
        for _ in 0 ..< 25 {
            if metrics.peerDeviceName != nil { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        if metrics.peerDeviceName == nil {
            AppLog("Peer info not received after 5s, proceeding with Unknown", level: .warning, category: "Agent")
        }

        let runner = TestSuiteRunner(connectionManager: manager, metrics: metrics)
        runner.config = config
        engine.testSuiteRunner = runner
        testRunner = runner

        // Monitor progress
        let progressTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                testProgress = runner.progress
                testPhase = runner.currentPhase?.rawValue ?? ""
                liveLatency = runner.liveLatency
                if let phase = runner.currentPhase {
                    sendStatus("running", detail: "\(phase.rawValue) — \(Int(runner.progress * 100))%")
                }
            }
        }

        let report = await runner.runFullSuite()
        progressTask.cancel()

        // Send report to conductor
        if let report {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(report) {
                conductorConnection?.send(.orchestrationReport(reportJSON: data))
            }
            sendStatus("completed", detail: "Test complete — \(report.results.overallGrade)")
        } else {
            sendStatus("failed", detail: "Test suite failed to produce a report")
        }

        // Clean up partner connection
        manager.onConnectionLost = nil
        engine.stop()
        manager.disconnect()
        partnerEngine = nil
        partnerConnection = nil
        testRunner = nil
        status = .idle
        testPartnerName = ""
        testProgress = 0
    }

    // MARK: - Conductor Communication

    private func sendStatus(_ phase: String, detail: String) {
        conductorConnection?.send(.orchestrationStatus(phase: phase, detail: detail))
    }
}
