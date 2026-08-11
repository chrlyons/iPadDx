import Foundation
import Network
import UIKit

@MainActor
@Observable
class DiagnosticEngine {
    var metrics: DiagnosticMetrics
    weak var peer: PeerDevice?
    var onPeerNameUpdated: ((String) -> Void)?
    var onTestSuiteStatus: ((DiagnosticMessage) -> Void)?
    var onReportReceived: ((Data) -> Void)?
    var onRemoteDisconnect: (() -> Void)?
    var onOrchestration: ((DiagnosticMessage) -> Void)?
    var testSuiteRunner: TestSuiteRunner?

    private var connectionManager: ConnectionManager
    private var pingTimer: Timer?
    private var pendingPings: [UUID: TimeInterval] = [:]
    private var throughputTestStart: Date?
    private var throughputTestID: UUID?
    private var throughputBytesSent: Int = 0
    private var incomingThroughputStartTime: Date?
    private var incomingThroughputTestID: UUID?
    private var incomingThroughputExpectedBytes: Int = 0
    private var incomingThroughputBytesReceived: Int = 0
    /// Fails an inbound transfer that stalls, so a dropped sender can't leave the
    /// receiver waiting forever for bytes that will never arrive.
    private var incomingThroughputTimeout: Task<Void, Never>?
    private let maxLatencyHistory = DiagnosticMetrics.defaultLatencyHistory
    private var lastPathUpdate: TimeInterval = 0
    private var systemTimer: Timer?
    // Responder-side metric collection during remote test
    private var responderTestActive = false
    private var responderCpuSamples: [Double] = []
    private var responderPeakMemoryMB: Double = 0
    private var responderWorstThermal: String = "Nominal"
    private var responderBatteryStart: Float = -1
    private var metricsBroadcastTask: Task<Void, Never>?

    init(connectionManager: ConnectionManager, metrics: DiagnosticMetrics) {
        self.connectionManager = connectionManager
        self.metrics = metrics
    }

    func start() {
        SystemMonitor.enableBatteryMonitoring()
        metrics.connectionStartTime = Date()
        metrics.batteryAtConnectionStart = SystemMonitor.batteryLevel()
        metrics.logEvent("Connected")
        // Record why connections end — this is what populates the disconnect
        // history and root-cause display on the dashboard.
        connectionManager.onDisconnect = { [weak self] reason, detail in
            self?.metrics.logDisconnect(reason: reason, detail: detail)
        }
        sendPeerInfo()
        startPingLoop()
        startSystemMonitor()
        updatePathInfo()
        updateSystemMetrics()
    }

    /// Tears the engine down. This is also called for ordinary mode transitions
    /// (entering agent mode, for example), so it must NOT count as a disconnect —
    /// real drops are recorded through `ConnectionManager.onDisconnect`, which is
    /// the sole writer of the disconnect history and count.
    func stop() {
        pingTimer?.invalidate()
        pingTimer = nil
        systemTimer?.invalidate()
        systemTimer = nil
        metricsBroadcastTask?.cancel()
        metricsBroadcastTask = nil
        incomingThroughputTimeout?.cancel()
        incomingThroughputTimeout = nil
        incomingThroughputTestID = nil
        incomingThroughputStartTime = nil
        pendingPings.removeAll()
        metrics.logEvent("Engine stopped")
    }

    func handleMessage(_ data: Data) {
        guard let message = try? DiagnosticMessage.decode(from: data) else { return }

        switch message {
        case let .ping(id, timestamp):
            connectionManager.send(.pong(id: id, originalTimestamp: timestamp))

        case let .pong(id, originalTimestamp):
            let rtt = (ProcessInfo.processInfo.systemUptime - originalTimestamp) * 1000
            pendingPings.removeValue(forKey: id)
            metrics.latencyMs = rtt
            metrics.pongsReceived += 1
            metrics.appendLatency(rtt, maxHistory: maxLatencyHistory)

        case let .peerInfo(deviceName, osVersion, model, modelNumber, stableID, ssid, bssid):
            metrics.peerDeviceName = deviceName
            metrics.peerOSVersion = osVersion
            metrics.peerModel = model
            metrics.peerModelNumber = modelNumber
            metrics.peerSSID = ssid
            metrics.peerBSSID = bssid
            peer?.name = deviceName
            peer?.stableDeviceID = stableID
            peer?.chipFamily = iPadCatalog.chipFamily(for: model, modelNumber: modelNumber)
            peer?.model = model
            onPeerNameUpdated?(deviceName)

        case let .throughputStart(testID, byteCount):
            // Remote is starting a throughput test — start the clock and the byte counter.
            beginIncomingThroughput(testID: testID, expectedBytes: byteCount)

        case let .throughputData(testID, payload):
            // Count the bytes that actually arrived. When the full transfer has landed,
            // ack back with the measurement — the *receiver* is the authority on throughput.
            guard testID == incomingThroughputTestID else { break }
            incomingThroughputBytesReceived += payload.count
            if incomingThroughputBytesReceived >= incomingThroughputExpectedBytes {
                finishIncomingThroughput()
            }

        case let .throughputAck(testID, bytesReceived, duration):
            // The peer measured our transfer and sent the result back.
            //
            // There are two independent senders of throughput transfers: this engine's
            // own dashboard test, and TestSuiteRunner's phase (which mints its own id).
            // Each filters on its OWN id, so the ack must be offered to both — gating
            // the forward on the engine's id silently starved the suite phase.
            guard duration > 0, bytesReceived > 0 else { break }
            if testID == throughputTestID {
                metrics.throughputBytesPerSec = Double(bytesReceived) / duration
                metrics.throughputTestInProgress = false
                throughputTestID = nil
            }
            testSuiteRunner?.handleThroughputAck(
                testID: testID,
                bytesReceived: bytesReceived,
                duration: duration
            )

        case let .testPing(id, sequence, timestamp):
            connectionManager.send(.testPong(id: id, sequence: sequence, originalTimestamp: timestamp))

        case .testPong:
            testSuiteRunner?.handleTestMessage(message)

        case let .testSuiteStatus(running, _):
            if running, !responderTestActive {
                // Remote test starting — begin collecting responder metrics
                responderTestActive = true
                responderCpuSamples.removeAll()
                responderPeakMemoryMB = 0
                responderWorstThermal = "Nominal"
                responderBatteryStart = SystemMonitor.batteryLevel()
                startMetricsBroadcast()
            } else if !running, responderTestActive {
                // Remote test ended — send our metrics back
                responderTestActive = false
                metricsBroadcastTask?.cancel()
                metricsBroadcastTask = nil
                sendResponderMetrics()
            }
            onTestSuiteStatus?(message)

        case let .liveMetrics(cpu, memoryMB, thermalState, _):
            metrics.appendRemoteMetrics(cpu: cpu, memoryMB: memoryMB, thermalState: thermalState)

        case let .responderMetrics(peakCpu, avgCpu, peakMemoryMB, thermalState, batteryDrain):
            testSuiteRunner?.handleResponderMetrics(
                peakCpu: peakCpu, avgCpu: avgCpu,
                peakMemoryMB: peakMemoryMB,
                thermalState: thermalState,
                batteryDrain: batteryDrain
            )

        case let .reportSync(reportJSON):
            onReportReceived?(reportJSON)

        case .disconnect:
            onRemoteDisconnect?()

        case .roleAssignment, .orchestrateTest, .orchestrationStatus,
             .orchestrationReport, .orchestrationCancel, .agentCapabilities:
            onOrchestration?(message)
        }

        // Only update path/bytes periodically to avoid excessive re-renders during bursts
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastPathUpdate > 1.0 {
            updatePathInfo()
            updateByteCounters()
            lastPathUpdate = now
        }
    }

    /// Runs a real throughput transfer to the peer.
    ///
    /// Every chunk carries actual payload bytes; the peer counts what arrives and
    /// replies with `throughputAck`, which is what sets `metrics.throughputBytesPerSec`.
    /// Nothing here estimates or extrapolates the rate.
    func runThroughputTest(byteCount: Int = 10_000_000) {
        guard !metrics.throughputTestInProgress else { return }
        metrics.throughputTestInProgress = true

        let testID = UUID()
        throughputTestID = testID
        throughputBytesSent = 0
        throughputTestStart = Date()

        connectionManager.send(.throughputStart(testID: testID, byteCount: byteCount))

        Task { @MainActor in
            let sent = await Self.sendThroughputPayload(
                over: connectionManager,
                testID: testID,
                byteCount: byteCount
            )
            throughputBytesSent = sent

            // The measurement arrives via .throughputAck. If the peer never acks
            // (dropped connection, old build), give up rather than reporting a number
            // we did not measure.
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            if throughputTestID == testID {
                AppLog(
                    "Throughput test \(testID) got no ack from peer — no result recorded",
                    level: .warning,
                    category: "Engine"
                )
                // Clear the previous run's figure rather than leaving it on screen as
                // if it were this run's result.
                metrics.throughputBytesPerSec = 0
                metrics.throughputTestInProgress = false
                throughputTestID = nil
            }
        }
    }

    /// Streams `byteCount` real bytes as framed `throughputData` messages, awaiting
    /// each send's transport completion so the transfer applies genuine backpressure.
    /// Returns the number of payload bytes actually handed to the transport.
    static func sendThroughputPayload(
        over connectionManager: ConnectionManager,
        testID: UUID,
        byteCount: Int,
        isCancelled: () -> Bool = { false },
        onProgress: (Double) -> Void = { _ in }
    ) async -> Int {
        var remaining = byteCount
        var sent = 0
        while remaining > 0 {
            if isCancelled() {
                break
            }
            let size = min(ThroughputPayload.chunkSize, remaining)
            let queued = await connectionManager.sendAwaitingCompletion(
                .throughputData(testID: testID, payload: ThroughputPayload.chunk(ofSize: size))
            )
            if !queued {
                break
            }
            remaining -= size
            sent += size
            onProgress(Double(sent) / Double(byteCount))
        }
        return sent
    }

    // MARK: - Inbound throughput measurement

    private func beginIncomingThroughput(testID: UUID, expectedBytes: Int) {
        incomingThroughputTimeout?.cancel()
        incomingThroughputTestID = testID
        incomingThroughputExpectedBytes = expectedBytes
        incomingThroughputBytesReceived = 0
        incomingThroughputStartTime = Date()

        incomingThroughputTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard let self, incomingThroughputTestID == testID else { return }
            AppLog(
                "Inbound throughput \(testID) stalled at \(incomingThroughputBytesReceived)/\(expectedBytes) bytes",
                level: .warning,
                category: "Engine"
            )
            // Ack what genuinely arrived so the sender reports a real (degraded) rate
            // rather than hanging.
            finishIncomingThroughput()
        }
    }

    private func finishIncomingThroughput() {
        guard let testID = incomingThroughputTestID,
              let startTime = incomingThroughputStartTime else { return }
        let elapsed = Date().timeIntervalSince(startTime)
        let received = incomingThroughputBytesReceived

        incomingThroughputTimeout?.cancel()
        incomingThroughputTimeout = nil
        incomingThroughputTestID = nil
        incomingThroughputStartTime = nil
        incomingThroughputBytesReceived = 0

        guard received > 0, elapsed > 0 else { return }
        connectionManager.send(.throughputAck(
            testID: testID,
            bytesReceived: received,
            duration: elapsed
        ))
    }

    // MARK: - Private

    private func startPingLoop() {
        pingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sendPing()
            }
        }
    }

    private func sendPing() {
        let id = UUID()
        let timestamp = ProcessInfo.processInfo.systemUptime
        pendingPings[id] = timestamp
        metrics.pingsSent += 1
        connectionManager.send(.ping(id: id, timestamp: timestamp))

        // Count pings older than 3 seconds as lost, then remove them
        let cutoff = timestamp - 3
        let timedOut = pendingPings.filter { $0.value < cutoff }
        if !timedOut.isEmpty {
            metrics.pingsLost += timedOut.count
        }
        pendingPings = pendingPings.filter { $0.value >= cutoff }
    }

    func sendPeerInfo() {
        let info = DeviceIdentifier.localDeviceInfo()
        let stableID = DeviceIdentifier.stableID
        // Fetch WiFi info asynchronously, send peer info with whatever we have
        Task {
            let wifi = await SystemMonitor.currentWiFi()
            connectionManager.send(.peerInfo(
                deviceName: info.name,
                osVersion: info.osVersion,
                model: info.model,
                modelNumber: info.modelNumber,
                stableID: stableID,
                ssid: wifi?.ssid,
                bssid: wifi?.bssid
            ))
        }
    }

    private func updatePathInfo() {
        guard connectionManager.isConnected, let path = connectionManager.currentPath else { return }
        metrics.pathStatus = path.status
        metrics.isExpensive = path.isExpensive
        metrics.isConstrained = path.isConstrained
        if let iface = path.availableInterfaces.first {
            // A change of interface mid-test means the link moved underneath the
            // measurement — worth recording, because it invalidates comparisons.
            if let previous = metrics.interfaceName, previous != iface.name {
                metrics.pathChangeCount += 1
                metrics.logEvent("Link changed: \(previous) → \(iface.name)")
            }
            metrics.interfaceType = iface.type
            metrics.interfaceName = iface.name
        }
    }

    private func updateByteCounters() {
        metrics.bytesSent = connectionManager.totalBytesSent
        metrics.bytesReceived = connectionManager.totalBytesReceived
    }

    private func startSystemMonitor() {
        systemTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateSystemMetrics()
            }
        }
    }

    private func updateSystemMetrics() {
        let snap = SystemMonitor.snapshot()
        metrics.batteryLevel = snap.batteryLevel
        metrics.batteryState = SystemMonitor.batteryStateString(snap.batteryState)
        metrics.thermalState = SystemMonitor.thermalStateString(snap.thermalState)
        metrics.cpuUsage = snap.cpuUsage
        metrics.memoryUsedMB = snap.memoryUsedMB
        metrics.memoryTotalMB = snap.memoryTotalMB

        // Collect responder-side samples while a remote test is active
        if responderTestActive {
            responderCpuSamples.append(snap.cpuUsage)
            responderPeakMemoryMB = max(responderPeakMemoryMB, snap.memoryUsedMB)
            let thermal = SystemMonitor.thermalStateString(snap.thermalState)
            let thermalOrder = ["Nominal", "Fair", "Serious", "Critical"]
            if let currentIdx = thermalOrder.firstIndex(of: thermal),
               let worstIdx = thermalOrder.firstIndex(of: responderWorstThermal),
               currentIdx > worstIdx
            {
                responderWorstThermal = thermal
            }
        }
    }

    private func startMetricsBroadcast() {
        metricsBroadcastTask?.cancel()
        metricsBroadcastTask = Task {
            while !Task.isCancelled {
                let snap = SystemMonitor.snapshot()
                connectionManager.send(.liveMetrics(
                    cpu: snap.cpuUsage, memoryMB: snap.memoryUsedMB,
                    thermalState: SystemMonitor.thermalStateString(snap.thermalState),
                    timestamp: Date().timeIntervalSince1970
                ))
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func sendResponderMetrics() {
        let peakCpu = responderCpuSamples.max() ?? 0
        let avgCpu = responderCpuSamples.isEmpty ? 0 : responderCpuSamples
            .reduce(0, +) / Double(responderCpuSamples.count)
        let batteryEnd = SystemMonitor.batteryLevel()
        let drain: Double = (responderBatteryStart >= 0 && batteryEnd >= 0)
            ? max(0, Double(responderBatteryStart - batteryEnd) * 100)
            : 0

        connectionManager.send(.responderMetrics(
            peakCpu: peakCpu,
            avgCpu: avgCpu,
            peakMemoryMB: responderPeakMemoryMB,
            thermalState: responderWorstThermal,
            batteryDrain: drain
        ))
    }
}
