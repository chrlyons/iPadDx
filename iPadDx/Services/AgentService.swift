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
    private var testRunner: TestSuiteRunner?
    private let serviceType = "_ipadconn._tcp"

    func configure(conductorConnection: ConnectionManager, conductorName: String) {
        self.conductorConnection = conductorConnection
        self.conductorName = conductorName
        status = .idle
    }

    func handleOrchestration(_ message: DiagnosticMessage) {
        switch message {
        case let .orchestrateTest(targetDeviceName, configJSON, role):
            let config = (try? JSONDecoder().decode(TestSuiteConfig.self, from: configJSON)) ?? .default
            if role == "responder" {
                // Just prepare to accept incoming connection — don't initiate
                status = .connecting
                testPartnerName = targetDeviceName
                sendStatus("preparing", detail: "Waiting for \(targetDeviceName) to connect")
            } else {
                // Controller — initiate connection and run tests
                Task { await executeTest(targetName: targetDeviceName, config: config) }
            }

        case .orchestrationCancel:
            cancelTest()

        default:
            break
        }
    }

    func cancelTest() {
        partnerConnection?.disconnect()
        partnerConnection = nil
        testRunner = nil
        status = .idle
        testPartnerName = ""
        sendStatus("cancelled", detail: "Test cancelled by conductor")
    }

    /// Accept an incoming connection from a test partner (another agent)
    func acceptTestPartnerConnection(_ conn: NWConnection) {
        let manager = ConnectionManager()
        partnerConnection = manager

        let metrics = DiagnosticMetrics()
        let engine = DiagnosticEngine(connectionManager: manager, metrics: metrics)

        manager.accept(conn) { data in
            Task { @MainActor in
                engine.handleMessage(data)
            }
        }

        Task {
            for _ in 0 ..< 100 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if manager.isConnected {
                    engine.start()
                    return
                }
            }
        }
    }

    func reset() {
        cancelTest()
        conductorConnection = nil
        conductorName = ""
        status = .idle
    }

    // MARK: - Test Execution

    private func executeTest(targetName: String, config _: TestSuiteConfig) async {
        testPartnerName = targetName
        status = .connecting

        sendStatus("connecting", detail: "Connecting to \(targetName)")

        // Browse for the target device
        guard let endpoint = await findDevice(named: targetName) else {
            status = .failed
            sendStatus("failed", detail: "Could not find \(targetName)")
            return
        }

        // Connect to the target
        let manager = ConnectionManager()
        partnerConnection = manager

        let metrics = DiagnosticMetrics()
        let engine = DiagnosticEngine(connectionManager: manager, metrics: metrics)

        var connected = false
        manager.connect(to: endpoint) { data in
            Task { @MainActor in
                engine.handleMessage(data)
            }
        }

        // Wait for connection
        for _ in 0 ..< 100 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if manager.isConnected {
                connected = true
                break
            }
        }

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

        // Wait for peer info exchange
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        let runner = TestSuiteRunner(connectionManager: manager, metrics: metrics)
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
        engine.stop()
        manager.disconnect()
        partnerConnection = nil
        testRunner = nil
        status = .idle
        testPartnerName = ""
        testProgress = 0
    }

    // MARK: - Device Discovery

    private func findDevice(named name: String) async -> NWEndpoint? {
        await withCheckedContinuation { continuation in
            let params = NWParameters()
            params.includePeerToPeer = true
            let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: params)
            var found = false

            browser.browseResultsChangedHandler = { results, _ in
                guard !found else { return }
                for result in results {
                    if case let .service(serviceName, _, _, _) = result.endpoint, serviceName == name {
                        found = true
                        browser.cancel()
                        continuation.resume(returning: result.endpoint)
                        return
                    }
                }
            }

            browser.start(queue: .main)

            // Timeout after 10 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                guard !found else { return }
                found = true
                browser.cancel()
                continuation.resume(returning: nil)
            }
        }
    }

    // MARK: - Conductor Communication

    private func sendStatus(_ phase: String, detail: String) {
        conductorConnection?.send(.orchestrationStatus(phase: phase, detail: detail))
    }
}
