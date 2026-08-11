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
        if bridgeTransport == "native" {
            return pair.label
        }
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
    var maxRetries: Int = 2
    var retryDelay: TimeInterval = 5
    private(set) var retryCount: [UUID: Int] = [:]
    /// Runs that were never executed (device offline, unschedulable). Counted separately
    /// from completedCount so "completed" only ever means "produced a measurement".
    private(set) var skippedCount: Int = 0
    /// Runs that ended in a terminal failure.
    private(set) var failedCount: Int = 0
    /// Runs stopped by queue cancellation — neither a measurement nor a failure.
    private(set) var cancelledCount: Int = 0

    /// Every run that reached a terminal state, however it ended.
    var finishedCount: Int {
        completedCount + failedCount + cancelledCount + skippedCount
    }

    /// Runs a failed attempt asked the scheduler to try again.
    private var requeueBuffer: [TestRun] = []

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

    /// Returns the queue to `.idle` so a repopulated queue is visible and editable
    /// again after a previous run finished in `.completed`.
    private func reopenQueueIfFinished() {
        if queueStatus == .completed {
            queueStatus = .idle
        }
    }

    func addPair(_ deviceA: PeerDevice, _ deviceB: PeerDevice) {
        reopenQueueIfFinished()
        let pair = TestPair(deviceA: deviceA, deviceB: deviceB)
        for bridge in selectedBridges {
            testQueue.append(TestRun(pair: pair, bridgeTransport: bridge))
        }
    }

    func removeRun(_ run: TestRun) {
        testQueue.removeAll { $0.id == run.id }
    }

    func generateAllPairs() {
        reopenQueueIfFinished()
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

        /// A pair involving the conductor can only run native (its own connections are
        /// never bridged), so don't queue combinations that are guaranteed to be refused.
        func canRun(_ pair: TestPair, on bridge: String) -> Bool {
            guard bridge != "native" else { return true }
            return pair.deviceA.id != selfDeviceID && pair.deviceB.id != selfDeviceID
        }
        // Interleave bridges across pairs to prevent thermal throttling:
        // A→B [native], C→A [native], A→B [cordova], B→C [native], C→A [cordova], ...
        if selectedBridges.count <= 1 {
            let bridge = selectedBridges.first ?? "native"
            for pair in pairs where canRun(pair, on: bridge) {
                testQueue.append(TestRun(pair: pair, bridgeTransport: bridge))
            }
        } else {
            // Offset each bridge's pair order so the same pair is not run back-to-back
            // under two bridges. Round-robining the queues at the same index — which is
            // what this used to do — produced pair0[native], pair0[cordova], … i.e. the
            // exact adjacency the interleave is meant to avoid.
            for step in 0 ..< pairs.count {
                for (bridgeIndex, bridge) in selectedBridges.enumerated() {
                    let pairIndex = (step + bridgeIndex * max(1, pairs.count / selectedBridges.count))
                        % pairs.count
                    guard canRun(pairs[pairIndex], on: bridge) else { continue }
                    testQueue.append(TestRun(pair: pairs[pairIndex], bridgeTransport: bridge))
                }
            }
        }
    }

    private let selfDeviceID = DeviceIdentifier.stableID
    var conductorBonjourName: String = ""
    private var selfBusy = false
    /// The conductor's own in-flight suite, when it is participating in a run.
    private var selfRunner: TestSuiteRunner?

    func cancelQueue() {
        guard queueStatus != .idle, queueStatus != .completed else { return }
        cancelRequested = true
        log("Queue cancellation requested", level: .warning)

        // Stop the conductor's own suite explicitly. Cancelling the wrapper Task is
        // not enough: every pacing delay inside the runner is `try? await Task.sleep`,
        // which throws instantly in a cancelled task and is swallowed by the `try?`,
        // so the suite would race through all remaining phases at full speed.
        selfRunner?.cancel()

        // Cancel all active tasks
        for (_, task) in activeTasks {
            task.cancel()
        }

        // Send cancel to all agents that are currently testing
        for conn in fleet where conn.agentStatus == .testing {
            conn.connectionManager.send(.orchestrationCancel)
            conn.agentStatus = .idle
            conn.currentTestPartner = nil
            conn.currentTestPartnerID = nil
            conn.testProgress = 0
            conn.testPhase = ""
        }
        selfBusy = false
    }

    /// Runs every queued pair.
    ///
    /// - Parameter preservingResults: keep results from the previous queue. Used by
    ///   "Re-run Failed" so retrying does not erase the successes already on screen.
    func runQueue(preservingResults: Bool = false) async {
        // Reentrancy guard: two concurrent queues would double-book every device.
        guard !isQueueRunning, !testQueue.isEmpty else { return }
        cancelRequested = false
        let total = testQueue.count
        queueStatus = .running(pairIndex: 0, total: total)
        if !preservingResults {
            completedReports.removeAll()
            retryCount.removeAll()
        }
        failedRuns.removeAll()
        skippedCount = 0
        failedCount = 0
        cancelledCount = 0
        completedCount = 0
        runningPairs.removeAll()
        requeueBuffer.removeAll()

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
            // Pick up any run a failed attempt asked to retry.
            if !requeueBuffer.isEmpty {
                remaining.append(contentsOf: requeueBuffer)
                requeueBuffer.removeAll()
            }
            // Prune runs where a device has gone offline
            let deadRuns = remaining.filter { run in
                let isSelfA = run.deviceA.id == selfDeviceID
                let isSelfB = run.deviceB.id == selfDeviceID
                if !isSelfA, fleet.first(where: { $0.peer.id == run.deviceA.id }) == nil {
                    return true
                }
                if !isSelfB, fleet.first(where: { $0.peer.id == run.deviceB.id }) == nil {
                    return true
                }
                return false
            }
            for run in deadRuns {
                remaining.removeAll { $0.id == run.id }
                // A run that never happened is not a completed measurement.
                skippedCount += 1
                failedRuns.append(run)
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
                        guard let self else { return }
                        let disposition = await executeRun(run)
                        runningPairs.removeAll { $0 == run.label }
                        switch disposition {
                        case .completed:
                            completedCount += 1
                        case .failed:
                            failedCount += 1
                        case .cancelled:
                            cancelledCount += 1
                        case .requeued:
                            await awaitRetryDelay()
                            if cancelRequested {
                                failedRuns.append(run)
                                failedCount += 1
                            } else {
                                requeueBuffer.append(run)
                            }
                        }
                        // Progress reflects everything finished, not just successes.
                        queueStatus = .running(pairIndex: finishedCount, total: total)
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
                    // Nothing is running and nothing can start — the remaining runs are
                    // unrunnable. Record them as failures instead of silently dropping
                    // them and then reporting "All tests completed".
                    if !remaining.isEmpty {
                        log(
                            "\(remaining.count) run(s) could not be scheduled — devices never became available",
                            level: .error
                        )
                        for run in remaining {
                            failedRuns.append(run)
                            skippedCount += 1
                        }
                        remaining.removeAll()
                    }
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
            conn.currentTestPartnerID = nil
            conn.testProgress = 0
            conn.testPhase = ""
        }
        selfBusy = false

        var parts = ["\(completedCount) completed"]
        if failedCount > 0 {
            parts.append("\(failedCount) failed")
        }
        if cancelledCount > 0 {
            parts.append("\(cancelledCount) cancelled")
        }
        if skippedCount > 0 {
            parts.append("\(skippedCount) skipped")
        }
        let breakdown = parts.joined(separator: ", ")
        if cancelRequested {
            log("Queue cancelled — \(breakdown) of \(total)", level: .warning)
        } else {
            log(
                "Queue finished — \(breakdown) of \(total)",
                level: failedCount > 0 ? .warning : .success
            )
        }
        runningPairs.removeAll()
        testQueue.removeAll()
        let wasCancelled = cancelRequested
        cancelRequested = false
        selfRunner = nil
        // Only claim completion when the queue actually ran to the end. Reporting
        // `.completed` after a cancel made the dashboard say "All tests completed".
        queueStatus = wasCancelled ? .failed("Cancelled — \(breakdown)") : .completed
    }

    /// Human-readable outcome of the last finished queue.
    var lastQueueBreakdown: String {
        var parts = ["\(completedCount) completed"]
        if failedCount > 0 {
            parts.append("\(failedCount) failed")
        }
        if cancelledCount > 0 {
            parts.append("\(cancelledCount) cancelled")
        }
        if skippedCount > 0 {
            parts.append("\(skippedCount) skipped")
        }
        return parts.joined(separator: ", ")
    }

    /// True while the conductor device itself is one of the endpoints of a running test.
    /// The self device card uses this instead of queue-level state, which said "Testing"
    /// for the whole queue regardless of whether the conductor was involved.
    var selfIsTesting: Bool {
        selfBusy
    }

    /// True only while a queue is actually executing.
    ///
    /// Conductor controls gate on this rather than on `queueStatus == .idle`: the
    /// terminal `.completed` state is not idle, so gating on idle left every control
    /// permanently disabled after the first successful queue.
    var isQueueRunning: Bool {
        if case .running = queueStatus {
            return true
        }
        return false
    }

    // MARK: - Run Execution

    /// How a single run ended.
    enum RunOutcome {
        case succeeded
        case cancelled
        /// Failed for a reason another attempt might survive (timeout, disconnect).
        case retryableFailure
        /// Failed for a reason retrying cannot change (unhealthy bridge, unsupported
        /// bridge, device missing from the fleet).
        case permanentFailure
    }

    /// What the scheduler should record for a finished attempt.
    ///
    /// A plain Bool conflated success, cancellation and terminal failure, so every
    /// one of them incremented `completedCount` — a queue where nothing worked still
    /// reported "N/N completed".
    enum RunDisposition {
        /// Produced a measurement.
        case completed
        /// Terminal failure — recorded in `failedRuns`.
        case failed
        /// Stopped because the queue was cancelled. Not a measurement, not a failure.
        case cancelled
        /// Will be attempted again.
        case requeued
    }

    /// Runs one pair and reports how it ended.
    private func executeRun(_ run: TestRun) async -> RunDisposition {
        let isSelfA = run.deviceA.id == selfDeviceID
        let isSelfB = run.deviceB.id == selfDeviceID

        // The scheduler marks both endpoints busy BEFORE launching this task, so every
        // exit path must release them. An early refusal that skipped the release left
        // the devices permanently busy and starved the rest of the queue.
        defer { releaseEndpoints(for: run) }

        let outcome: RunOutcome = if isSelfA || isSelfB {
            await executeSelfRun(run, isSelfA: isSelfA)
        } else {
            await executeRemoteRun(run)
        }

        switch outcome {
        case .succeeded:
            return .completed
        case .cancelled:
            return .cancelled
        case .permanentFailure:
            failedRuns.append(run)
            return .failed
        case .retryableFailure:
            // Retrying is the SCHEDULER's job. Re-entering executeRun from inside the
            // failing frame would run the retry underneath the failed run's own cleanup.
            let attempts = retryCount[run.id, default: 0]
            guard !cancelRequested else { return .cancelled }
            guard shouldRetry(run) else {
                failedRuns.append(run)
                if attempts > 0 {
                    log("\(run.label) failed after \(attempts) attempt(s)", level: .error)
                }
                return .failed
            }
            let nextAttempt = attempts + 1
            retryCount[run.id] = nextAttempt
            log(
                "Will retry \(run.label) (attempt \(nextAttempt)/\(maxRetries))",
                level: .warning
            )
            return .requeued
        }
    }

    /// Clears the busy marks the scheduler set for a run's endpoints.
    private func releaseEndpoints(for run: TestRun) {
        if run.deviceA.id == selfDeviceID || run.deviceB.id == selfDeviceID {
            selfBusy = false
        }
        for peer in [run.deviceA, run.deviceB] where peer.id != selfDeviceID {
            guard let conn = fleet.first(where: { $0.peer.id == peer.id }) else { continue }
            if conn.connectionManager.isConnected {
                conn.agentStatus = .idle
            }
            conn.currentTestPartner = nil
            conn.currentTestPartnerID = nil
            conn.testProgress = 0
            conn.testPhase = ""
        }
    }

    private func executeSelfRun(_ run: TestRun, isSelfA: Bool) async -> RunOutcome {
        // Refuse to run if the bridge failed to initialize — results would be invalid
        if run.bridgeTransport != "native", !BridgeRegistry.isBridgeHealthy(run.bridgeTransport) {
            log("Bridge \(run.bridgeTransport) not healthy, skipping self run", level: .error)
            return .permanentFailure
        }

        // The conductor's own fleet connection is always native (it is created when the
        // device joins the fleet, long before a bridge is chosen), so a bridged run with
        // the conductor as an endpoint cannot actually be bridged on this side. Refuse it
        // rather than emit a report labelled with a bridge that never carried the bytes.
        if run.bridgeTransport != "native" {
            log(
                "Skipping \(run.label): the conductor itself cannot be bridged — run bridge comparisons between two agents",
                level: .warning
            )
            return .permanentFailure
        }

        let agentPeer = isSelfA ? run.deviceB : run.deviceA
        guard let conn = fleet.first(where: { $0.peer.id == agentPeer.id }) else {
            log("Self run: \(agentPeer.name) not found in fleet", level: .error)
            return .permanentFailure
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
            runner.peerBonjourName = conn.peer.bonjourName
            if let engine = conn.diagnosticEngine {
                engine.testSuiteRunner = runner
            }
            selfRunner = runner
            let report = await runner.runFullSuite()
            selfRunner = nil
            var outcome: RunOutcome = .succeeded
            if let report, !runner.cancelRequested {
                // In self-run where conductor is sender (isSelfA):
                // localDevice = conductor (self), remoteDevice = the agent
                completedReports.append(patchDeviceInfo(in: report, controllerConn: nil, responderConn: conn))
                log("Self run completed: \(direction) — \(report.results.overallGrade)", level: .success)
            } else if runner.cancelRequested {
                log("Self run cancelled: \(direction)", level: .warning)
                outcome = .cancelled
            } else {
                log("Self run failed: \(direction) — no report generated", level: .error)
                outcome = .retryableFailure
            }
            if let engine = conn.diagnosticEngine {
                engine.testSuiteRunner = nil
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000) // settle
            return outcome
        } else {
            let config = TestSuiteConfig.default
            guard let configData = try? JSONEncoder().encode(config) else {
                return .permanentFailure
            }
            conn.connectionManager.send(.orchestrateTest(
                targetDeviceName: conductorBonjourName, configJSON: configData,
                role: "controller", bridgeTransport: run.bridgeTransport
            ))
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            let completed = await waitForTestCompletion(connection: conn, timeout: 180)

            var outcome: RunOutcome = .succeeded
            if completed {
                log("Self run completed: \(direction)", level: .success)
            } else if cancelRequested {
                log("Self run cancelled: \(direction)", level: .warning)
                outcome = .cancelled
            } else {
                let reason = conn.connectionManager.isConnected ? "timed out" : "device disconnected"
                log("Self run failed: \(direction) — \(reason)", level: .error)
                outcome = .retryableFailure
            }
            if !completed, conn.connectionManager.isConnected {
                conn.connectionManager.send(.orchestrationCancel)
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000) // settle
            return outcome
        }
    }

    private func executeRemoteRun(_ run: TestRun) async -> RunOutcome {
        guard let connA = fleet.first(where: { $0.peer.id == run.deviceA.id }),
              let connB = fleet.first(where: { $0.peer.id == run.deviceB.id })
        else {
            log("Remote run: devices not found in fleet", level: .error)
            return .permanentFailure
        }

        // Refuse to dispatch a bridge neither device advertised. Without this the run
        // is sent anyway and fails later with an opaque timeout.
        guard validateBridgeSupport(connA: connA, connB: connB, bridge: run.bridgeTransport) else {
            log("Skipping \(run.label) — bridge not supported by both devices", level: .error)
            return .permanentFailure
        }

        let config = TestSuiteConfig.default
        guard let configData = try? JSONEncoder().encode(config) else {
            return .permanentFailure
        }

        let bridgeTag = run.bridgeTransport == "native" ? "" : " [\(run.bridgeTransport)]"
        let label = "\(run.deviceA.name) → \(run.deviceB.name)\(bridgeTag)"
        log("Starting remote run: \(label)")

        connA.agentStatus = .testing
        connA.lastStatusUpdate = Date()
        connA.currentTestPartner = run.deviceB.name
        connA.currentTestPartnerID = run.deviceB.id
        connA.testProgress = 0
        connA.testPhase = ""
        connB.agentStatus = .testing
        connB.lastStatusUpdate = Date()
        connB.currentTestPartner = run.deviceA.name
        connB.currentTestPartnerID = run.deviceA.id
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

        var outcome: RunOutcome = .succeeded
        if completed {
            log("Remote run completed: \(label)", level: .success)
        } else if cancelRequested {
            log("Remote run cancelled: \(label)", level: .warning)
            outcome = .cancelled
        } else {
            let reason = connA.connectionManager.isConnected ? "timed out" : "device disconnected"
            log("Remote run failed: \(label) — \(reason)", level: .error)
            outcome = .retryableFailure
        }

        if !completed {
            if connA.connectionManager.isConnected {
                connA.connectionManager.send(.orchestrationCancel)
            }
            if connB.connectionManager.isConnected {
                connB.connectionManager.send(.orchestrationCancel)
            }
        }

        // Wait for responder (connB) to finish
        if connB.agentStatus == .testing {
            log("Waiting for responder \(run.deviceB.name) to finish...", level: .info)
            for _ in 0 ..< 20 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if connB.agentStatus != .testing {
                    break
                }
                if !connB.connectionManager.isConnected {
                    break
                }
            }
        }

        // Settle delay
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        if connA.connectionManager.isConnected {
            connA.agentStatus = .idle
            connA.currentTestPartner = nil
            connA.currentTestPartnerID = nil
            connA.testProgress = 0
            connA.testPhase = ""
        }
        if connB.connectionManager.isConnected {
            connB.agentStatus = .idle
            connB.currentTestPartner = nil
            connB.currentTestPartnerID = nil
            connB.testProgress = 0
            connB.testPhase = ""
        }

        return outcome
    }

    // MARK: - Message Handling

    private func handleAgentMessage(_ message: DiagnosticMessage, from connection: DeviceConnection?) {
        guard let connection else { return }

        switch message {
        case let .orchestrationStatus(phase, detail):
            connection.testPhase = detail
            connection.lastStatusUpdate = Date()
            switch phase {
            case "failed":
                log("\(connection.peer.name): \(detail)", level: .error)
                connection.agentStatus = .failed
            case "completed":
                log("\(connection.peer.name): \(detail)", level: .success)
                connection.agentStatus = .completed
            case "cancelled":
                // Previously unhandled, so a cancelled agent stayed stuck in .testing
                // on the conductor and was never logged.
                log("\(connection.peer.name): \(detail)", level: .warning)
                connection.agentStatus = .idle
                connection.currentTestPartner = nil
                connection.currentTestPartnerID = nil
                connection.testProgress = 0
            case "running":
                if let pct = parseProgress(from: detail) {
                    connection.testProgress = pct
                }
            default:
                break
            }

        case let .orchestrationReport(reportJSON):
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if cancelRequested {
                log("Ignoring report from \(connection.peer.name) — queue was cancelled", level: .warning)
                break
            }
            if let report = try? decoder.decode(TestReport.self, from: reportJSON) {
                // The controller agent sent this report. Its partner is the responder.
                // Resolve by stable id — display names are mutated by peerInfo.
                let responderConn = connection.currentTestPartnerID
                    .flatMap { id in fleet.first { $0.peer.id == id } }
                let patched = patchDeviceInfo(
                    in: report,
                    controllerConn: connection,
                    responderConn: responderConn
                )
                completedReports.append(patched)
            }

        case let .agentCapabilities(supportedBridges, appVersion, iosVersion):
            connection.supportedBridges = supportedBridges
            let vInfo = [appVersion, iosVersion].filter { !$0.isEmpty }.joined(separator: ", iOS ")
            log(
                "\(connection.peer.name) supports bridges: \(supportedBridges.joined(separator: ", "))\(vInfo.isEmpty ? "" : " (v\(vInfo))")"
            )

        default:
            break
        }
    }

    private func waitForTestCompletion(connection: DeviceConnection, timeout: Int) async -> Bool {
        for _ in 0 ..< (timeout * 2) {
            try? await Task.sleep(nanoseconds: 500_000_000)
            // Stop waiting as soon as the queue is being torn down.
            if cancelRequested {
                return false
            }
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

    // MARK: - Retry Logic (Feature #4)

    private func shouldRetry(_ run: TestRun) -> Bool {
        retryCount[run.id, default: 0] < maxRetries
    }

    /// Applies the retry delay before the scheduler re-runs a failed pair.
    /// Cancellation-aware: a cancelled queue must not sit out the delay.
    private func awaitRetryDelay() async {
        let step: UInt64 = 250_000_000
        var waited: TimeInterval = 0
        while waited < retryDelay, !cancelRequested {
            try? await Task.sleep(nanoseconds: step)
            waited += Double(step) / 1_000_000_000
        }
    }

    // MARK: - Capability Validation (Feature #9)

    func validateBridgeSupport(connA: DeviceConnection, connB: DeviceConnection, bridge: String) -> Bool {
        guard bridge != "native" else { return true }
        // An agent that has not yet advertised its capabilities is unknown, not
        // unsupported — refusing here would reject a perfectly capable device purely
        // on message timing.
        if connA.supportedBridges.isEmpty || connB.supportedBridges.isEmpty {
            log("Bridge capabilities not yet received — allowing '\(bridge)' to be attempted", level: .warning)
            return true
        }
        let aOK = connA.supportedBridges.contains(bridge)
        let bOK = connB.supportedBridges.contains(bridge)
        if !aOK || !bOK {
            var missing: [String] = []
            if !aOK {
                missing.append(connA.peer.name)
            }
            if !bOK {
                missing.append(connB.peer.name)
            }
            log("Bridge '\(bridge)' not supported by: \(missing.joined(separator: ", "))", level: .error)
            return false
        }
        return true
    }

    // MARK: - Event Log

    func log(_ message: String, level: ConductorEvent.EventLevel = .info) {
        let event = ConductorEvent(timestamp: Date(), level: level, message: message)
        eventLog.insert(event, at: 0)
        if eventLog.count > 100 {
            eventLog.removeLast()
        }
    }
}
