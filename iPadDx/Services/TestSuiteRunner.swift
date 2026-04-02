import Foundation
import UIKit

enum TestPhase: String, CaseIterable {
    case latencyBurst = "Latency Burst"
    case sustainedThroughput = "Throughput"
    case jitterMeasurement = "Jitter Stability"
    case packetLossStress = "Packet Loss Stress"
    case latencyUnderLoad = "Latency Under Load"
    case heavyLoad = "Heavy Load Stress"

    var icon: String {
        switch self {
        case .latencyBurst: "bolt.fill"
        case .sustainedThroughput: "arrow.up.arrow.down.circle.fill"
        case .jitterMeasurement: "waveform.path"
        case .packetLossStress: "exclamationmark.triangle.fill"
        case .latencyUnderLoad: "flame.fill"
        case .heavyLoad: "cpu"
        }
    }

    var color: String {
        switch self {
        case .latencyBurst: "blue"
        case .sustainedThroughput: "purple"
        case .jitterMeasurement: "orange"
        case .packetLossStress: "red"
        case .latencyUnderLoad: "orange"
        case .heavyLoad: "red"
        }
    }

    var shortDescription: String {
        switch self {
        case .latencyBurst: "100 rapid pings to measure round-trip time"
        case .sustainedThroughput: "10 MB data transfer to measure speed"
        case .jitterMeasurement: "150 samples measuring latency variation"
        case .packetLossStress: "500 aggressive pings at 10ms intervals"
        case .latencyUnderLoad: "Latency while saturating the connection"
        case .heavyLoad: "Concurrent data + pings for 15 seconds"
        }
    }

    var detailedDescription: String {
        switch self {
        case .latencyBurst:
            "Sends 100 ping-pong messages at 50ms intervals and measures the round-trip time for each. Reports min, max, average, median, and P95 latency. This is the baseline measurement of how fast data travels between the two devices over the local Wi-Fi network."
        case .sustainedThroughput:
            "Pushes 10 MB of data in 32 KB chunks and measures total transfer time. This tests the raw bandwidth capacity of the connection — how much data can flow between the devices per second. Important for apps that sync large files or stream content."
        case .jitterMeasurement:
            "Sends 150 ping-pong messages at 80ms intervals and measures how much the latency varies between consecutive samples. Low jitter means consistent, predictable performance. High jitter can cause lag spikes in real-time apps even when average latency is acceptable."
        case .packetLossStress:
            "Fires 500 pings at 10ms intervals — intentionally aggressive to stress the connection. Counts how many responses come back. Any packet loss indicates the network is being pushed beyond its reliable capacity, which can cause data retransmissions and timeouts."
        case .latencyUnderLoad:
            "Simultaneously sends heavy data traffic (800 throughput chunks) while measuring latency with 50 pings. Compares the under-load latency to the baseline from Phase 1. Shows how much real-world multitasking degrades connection responsiveness."
        case .heavyLoad:
            "Maximum stress test: 3 concurrent data generators plus 75 latency probes for 15 seconds. Simulates worst-case usage where multiple operations compete for bandwidth. Measures latency, throughput, and packet loss under extreme conditions."
        }
    }

    var whyItMatters: String {
        switch self {
        case .latencyBurst:
            "Directly affects how responsive device-to-device interactions feel."
        case .sustainedThroughput:
            "Determines how quickly large payloads (test content, media, results) can be transferred."
        case .jitterMeasurement:
            "High jitter causes unpredictable delays — even if average latency looks fine, spikes can disrupt timed operations."
        case .packetLossStress:
            "Lost packets must be retransmitted, adding latency and potentially causing timeouts. Even 1% loss degrades the experience."
        case .latencyUnderLoad:
            "Real-world connections are rarely idle. This shows whether the connection stays responsive when other data is flowing."
        case .heavyLoad:
            "Reveals the connection's breaking point. If this passes, the connection can handle anything the app throws at it."
        }
    }

    func isEnabled(in config: TestSuiteConfig) -> Bool {
        switch self {
        case .latencyBurst: config.runLatencyBurst
        case .sustainedThroughput: config.runThroughput
        case .jitterMeasurement: config.runJitter
        case .packetLossStress: config.runPacketLoss
        case .latencyUnderLoad: config.runLatencyUnderLoad
        case .heavyLoad: config.runHeavyLoad
        }
    }
}

enum PhaseStatus: Equatable {
    case pending
    case running
    case completed(String) // summary text
    case skipped
    case failed
}

enum SuiteState: Equatable {
    case idle
    case running
    case completed
    case failed(String)

    static func == (lhs: SuiteState, rhs: SuiteState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.running, .running), (.completed, .completed): true
        case let (.failed(a), .failed(b)): a == b
        default: false
        }
    }
}

@MainActor
@Observable
class TestSuiteRunner {
    var state: SuiteState = .idle
    var currentPhase: TestPhase?
    var progress: Double = 0
    var phaseProgress: Double = 0
    var lastReport: TestReport?
    var phaseStatuses: [TestPhase: PhaseStatus] = [:]
    var liveLatency: Double = 0
    var livePingCount: Int = 0
    var isWarmingUp: Bool = false
    var config: TestSuiteConfig = .default
    var responderMetrics: ResponderMetricsResult?
    /// Override bridge transport for the report. If nil, uses connectionManager.bridgeTransport.
    var bridgeTransportOverride: String?

    private let connectionManager: ConnectionManager
    private let metrics: DiagnosticMetrics
    private var pendingTestPongs: [UUID: (sequence: Int, timestamp: TimeInterval)] = [:]
    private var receivedTestPongs: [(sequence: Int, rtt: Double)] = []
    private var suiteStartTime: Date?
    private var cpuSamples: [Double] = []
    private var peakMemoryMB: Double = 0
    private var batteryStart: Float = -1
    private var worstThermalState: String = "Nominal"
    private var errorLog: [String] = []

    init(connectionManager: ConnectionManager, metrics: DiagnosticMetrics) {
        self.connectionManager = connectionManager
        self.metrics = metrics
    }

    func handleTestMessage(_ message: DiagnosticMessage) {
        switch message {
        case let .testPing(id, sequence, timestamp):
            connectionManager.send(.testPong(id: id, sequence: sequence, originalTimestamp: timestamp))
        case let .testPong(id, _, originalTimestamp):
            let rtt = (ProcessInfo.processInfo.systemUptime - originalTimestamp) * 1000
            if let pending = pendingTestPongs.removeValue(forKey: id) {
                receivedTestPongs.append((sequence: pending.sequence, rtt: rtt))
                liveLatency = rtt
                livePingCount = receivedTestPongs.count
            }
        default:
            break
        }
    }

    func handleResponderMetrics(
        peakCpu: Double, avgCpu: Double,
        peakMemoryMB: Double, thermalState: String,
        batteryDrain: Double
    ) {
        responderMetrics = ResponderMetricsResult(
            peakCpuUsage: peakCpu,
            avgCpuUsage: avgCpu,
            peakMemoryMB: peakMemoryMB,
            thermalStateDuringTest: thermalState,
            batteryDrainPercent: batteryDrain
        )
    }

    func runFullSuite() async -> TestReport? {
        guard state == .idle || state == .completed else { return nil }

        let cfg = config
        guard cfg.enabledPhaseCount > 0 else { return nil }

        SystemMonitor.enableBatteryMonitoring()
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "iPadDx test suite running"
        )
        suiteStartTime = Date()
        batteryStart = SystemMonitor.batteryLevel()
        cpuSamples.removeAll()
        peakMemoryMB = 0
        worstThermalState = "Nominal"
        errorLog.removeAll()
        responderMetrics = nil
        progress = 0
        state = .running
        isWarmingUp = false

        // Initialize phase statuses
        for phase in TestPhase.allCases {
            phaseStatuses[phase] = phase.isEnabled(in: cfg) ? .pending : .skipped
        }

        // Warm-up: settle the connection before real measurements
        if cfg.runWarmUp {
            isWarmingUp = true
            connectionManager.send(.testSuiteStatus(running: true, phase: "Warm-Up"))
            await runWarmUp(count: cfg.warmUpPingCount, intervalMs: cfg.warmUpIntervalMs)
            isWarmingUp = false
        }

        let enabledPhases = TestPhase.allCases.filter { $0.isEnabled(in: cfg) }
        let totalPhases = Double(enabledPhases.count)
        var phaseIndex = 0.0

        // Phase 1: Latency Burst
        let latency: LatencyBurstResult
        if cfg.runLatencyBurst {
            latency = await runPhase(.latencyBurst) {
                await self.runLatencyBurst(count: cfg.latencyBurstCount, intervalMs: cfg.latencyBurstIntervalMs)
            }
            if latency.sampleCount == 0 {
                errorLog
                    .append("Latency Burst: 0/\(cfg.latencyBurstCount) pongs received — remote may not be responding")
            } else if latency.sampleCount < cfg.latencyBurstCount / 2 {
                errorLog
                    .append(
                        "Latency Burst: only \(latency.sampleCount)/\(cfg.latencyBurstCount) pongs received — significant packet loss"
                    )
            }
            phaseStatuses[.latencyBurst] =
                .completed(
                    "Avg: \(String(format: "%.1fms", latency.avg)) | P95: \(String(format: "%.1fms", latency.p95))"
                )
            phaseIndex += 1
            progress = phaseIndex / totalPhases
            sampleSystem()
        } else {
            latency = LatencyBurstResult(min: 0, max: 0, avg: 0, median: 0, p95: 0, sampleCount: 0, samples: [])
        }

        // Phase 2: Sustained Throughput
        let throughput: ThroughputResult
        if cfg.runThroughput {
            throughput = await runPhase(.sustainedThroughput) {
                await self.runThroughputTest(bytes: cfg.throughputBytes)
            }
            phaseStatuses[.sustainedThroughput] = .completed(throughput.formattedSpeed)
            phaseIndex += 1
            progress = phaseIndex / totalPhases
            sampleSystem()
        } else {
            throughput = ThroughputResult(bytesPerSecond: 0, totalBytes: 0, durationSeconds: 0)
        }

        // Phase 3: Jitter
        let jitter: JitterResult
        if cfg.runJitter {
            jitter = await runPhase(.jitterMeasurement) {
                await self.runJitterTest(count: cfg.jitterSampleCount, intervalMs: cfg.jitterIntervalMs)
            }
            if jitter.sampleCount == 0 {
                errorLog.append("Jitter: 0/\(cfg.jitterSampleCount) pongs received — remote not responding to pings")
            }
            phaseStatuses[.jitterMeasurement] =
                .completed(
                    "Avg: \(String(format: "%.1fms", jitter.averageJitter)) | Max: \(String(format: "%.1fms", jitter.maxJitter))"
                )
            phaseIndex += 1
            progress = phaseIndex / totalPhases
            sampleSystem()
        } else {
            jitter = JitterResult(averageJitter: 0, maxJitter: 0, sampleCount: 0)
        }

        // Phase 4: Packet Loss Stress
        let packetLoss: PacketLossResult
        if cfg.runPacketLoss {
            packetLoss = await runPhase(.packetLossStress) {
                await self.runPacketLossStress(count: cfg.packetLossCount, intervalMs: cfg.packetLossIntervalMs)
            }
            if packetLoss.received == 0 {
                errorLog.append("Packet Loss: 0/\(packetLoss.sent) received — connection may be dead")
            } else if packetLoss.lostPercent > 50 {
                errorLog
                    .append(
                        "Packet Loss: \(String(format: "%.0f", packetLoss.lostPercent))% loss (\(packetLoss.received)/\(packetLoss.sent) received)"
                    )
            }
            phaseStatuses[.packetLossStress] =
                .completed(
                    "Loss: \(String(format: "%.1f%%", packetLoss.lostPercent)) (\(packetLoss.received)/\(packetLoss.sent))"
                )
            phaseIndex += 1
            progress = phaseIndex / totalPhases
            sampleSystem()
        } else {
            packetLoss = PacketLossResult(sent: 0, received: 0, lostPercent: 0, durationSeconds: 0)
        }

        // Phase 5: Latency Under Load
        let underLoad: LatencyUnderLoadResult
        if cfg.runLatencyUnderLoad {
            underLoad = await runPhase(.latencyUnderLoad) {
                await self.runLatencyUnderLoad(baselineAvg: latency.avg)
            }
            phaseStatuses[.latencyUnderLoad] =
                .completed(underLoad.formattedDegradation)
            phaseIndex += 1
            progress = phaseIndex / totalPhases
            sampleSystem()
        } else {
            underLoad = LatencyUnderLoadResult(baselineAvg: 0, underLoadAvg: 0, degradationPercent: 0, sampleCount: 0)
        }

        // Phase 6: Heavy Load Stress
        if cfg.runHeavyLoad {
            let heavy = await runPhase(.heavyLoad) {
                await self.runHeavyLoadStress()
            }
            phaseStatuses[.heavyLoad] =
                .completed(
                    "Avg: \(String(format: "%.1fms", heavy.avgLatency)) | Loss: \(String(format: "%.1f%%", heavy.packetLoss))"
                )
            phaseIndex += 1
            sampleSystem()
        }

        progress = 1.0

        // Build report
        let batteryEnd = SystemMonitor.batteryLevel()
        let batteryDrain: Double = (batteryStart >= 0 && batteryEnd >= 0) ? max(
            0,
            Double(batteryStart - batteryEnd) * 100
        ) : 0

        let systemResult = SystemMetricsResult(
            batteryStart: batteryStart,
            batteryEnd: batteryEnd,
            batteryDrainPercent: batteryDrain,
            peakCpuUsage: cpuSamples.max() ?? 0,
            avgCpuUsage: cpuSamples.isEmpty ? 0 : cpuSamples.reduce(0, +) / Double(cpuSamples.count),
            peakMemoryMB: peakMemoryMB,
            thermalStateDuringTest: worstThermalState
        )

        let remoteInfo = buildRemoteDeviceInfo()
        if remoteInfo.name == "Unknown" || remoteInfo.model == "Unknown" {
            errorLog.append("Peer info exchange failed — remote device is Unknown (peer info never received)")
        }

        // Signal test complete so responder sends its metrics
        connectionManager.send(.testSuiteStatus(running: false, phase: ""))

        // Wait briefly for responder metrics to arrive
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        let skipped = TestPhase.allCases.filter { !$0.isEnabled(in: cfg) }.map(\.rawValue)
        let grade = computeGrade(latency: latency, jitter: jitter, loss: packetLoss, underLoad: underLoad)

        let report = TestReport(
            id: UUID(),
            date: Date(),
            localDevice: buildLocalDeviceInfo(),
            remoteDevice: remoteInfo,
            results: TestSuiteResults(
                latencyBurst: latency,
                sustainedThroughput: throughput,
                jitterMeasurement: jitter,
                packetLossStress: packetLoss,
                latencyUnderLoad: underLoad,
                systemMetrics: systemResult,
                overallGrade: grade.rawValue,
                responderMetrics: responderMetrics
            ),
            durationSeconds: Date().timeIntervalSince(suiteStartTime ?? Date()),
            errors: errorLog.isEmpty ? nil : errorLog,
            skippedPhases: skipped.isEmpty ? nil : skipped,
            bridgeTransport: bridgeTransportOverride ?? connectionManager.bridgeTransport
        )

        lastReport = report
        state = .completed
        currentPhase = nil
        ProcessInfo.processInfo.endActivity(activity)
        return report
    }

    func reset() {
        state = .idle
        currentPhase = nil
        progress = 0
        phaseProgress = 0
        lastReport = nil
        phaseStatuses.removeAll()
        liveLatency = 0
        livePingCount = 0
    }

    // MARK: - Phase Runner

    private func runPhase<T>(_ phase: TestPhase, test: () async -> T) async -> T {
        currentPhase = phase
        phaseProgress = 0
        phaseStatuses[phase] = .running
        liveLatency = 0
        livePingCount = 0
        // Notify the responder what phase we're running
        connectionManager.send(.testSuiteStatus(running: true, phase: phase.rawValue))
        return await test()
    }

    // MARK: - Warm-Up

    private func runWarmUp(count: Int, intervalMs: Int) async {
        receivedTestPongs.removeAll()
        pendingTestPongs.removeAll()

        for i in 0 ..< count {
            let id = UUID()
            let timestamp = ProcessInfo.processInfo.systemUptime
            pendingTestPongs[id] = (sequence: i, timestamp: timestamp)
            connectionManager.send(.testPing(id: id, sequence: i, timestamp: timestamp))
            try? await Task.sleep(nanoseconds: UInt64(intervalMs) * 1_000_000)
        }

        // Brief wait for remaining responses
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        // Discard warm-up data
        receivedTestPongs.removeAll()
        pendingTestPongs.removeAll()
    }

    // MARK: - Test Phases

    private func runLatencyBurst(count: Int, intervalMs: Int) async -> LatencyBurstResult {
        receivedTestPongs.removeAll()
        pendingTestPongs.removeAll()

        for i in 0 ..< count {
            let id = UUID()
            let timestamp = ProcessInfo.processInfo.systemUptime
            pendingTestPongs[id] = (sequence: i, timestamp: timestamp)
            connectionManager.send(.testPing(id: id, sequence: i, timestamp: timestamp))
            phaseProgress = Double(i + 1) / Double(count)
            try? await Task.sleep(nanoseconds: UInt64(intervalMs) * 1_000_000)
        }

        try? await Task.sleep(nanoseconds: 2_000_000_000)

        let rtts = receivedTestPongs.sorted(by: { $0.sequence < $1.sequence }).map(\.rtt)
        return buildLatencyResult(rtts)
    }

    private func runThroughputTest(bytes: Int) async -> ThroughputResult {
        let startTime = Date()
        let chunkSize = 32768
        var remaining = bytes
        let total = bytes

        connectionManager.send(.throughputStart(testID: UUID(), byteCount: bytes))

        while remaining > 0 {
            connectionManager.send(.throughputData(testID: UUID()))
            remaining -= min(chunkSize, remaining)
            phaseProgress = Double(total - remaining) / Double(total)
            try? await Task.sleep(nanoseconds: 500_000)
        }

        let elapsed = Date().timeIntervalSince(startTime)
        return ThroughputResult(
            bytesPerSecond: Double(bytes) / max(elapsed, 0.001),
            totalBytes: bytes,
            durationSeconds: elapsed
        )
    }

    private func runJitterTest(count: Int, intervalMs: Int) async -> JitterResult {
        receivedTestPongs.removeAll()
        pendingTestPongs.removeAll()

        for i in 0 ..< count {
            let id = UUID()
            let timestamp = ProcessInfo.processInfo.systemUptime
            pendingTestPongs[id] = (sequence: i, timestamp: timestamp)
            connectionManager.send(.testPing(id: id, sequence: i, timestamp: timestamp))
            phaseProgress = Double(i + 1) / Double(count)
            try? await Task.sleep(nanoseconds: UInt64(intervalMs) * 1_000_000)
        }

        try? await Task.sleep(nanoseconds: 2_000_000_000)

        let rtts = receivedTestPongs.sorted(by: { $0.sequence < $1.sequence }).map(\.rtt)
        guard rtts.count >= 2 else {
            return JitterResult(averageJitter: 0, maxJitter: 0, sampleCount: rtts.count)
        }

        var diffs: [Double] = []
        for i in 1 ..< rtts.count {
            diffs.append(abs(rtts[i] - rtts[i - 1]))
        }

        return JitterResult(
            averageJitter: diffs.reduce(0, +) / Double(diffs.count),
            maxJitter: diffs.max() ?? 0,
            sampleCount: rtts.count
        )
    }

    private func runPacketLossStress(count: Int, intervalMs: Int) async -> PacketLossResult {
        receivedTestPongs.removeAll()
        pendingTestPongs.removeAll()
        let startTime = Date()

        for i in 0 ..< count {
            let id = UUID()
            let timestamp = ProcessInfo.processInfo.systemUptime
            pendingTestPongs[id] = (sequence: i, timestamp: timestamp)
            connectionManager.send(.testPing(id: id, sequence: i, timestamp: timestamp))
            phaseProgress = Double(i + 1) / Double(count)
            try? await Task.sleep(nanoseconds: UInt64(intervalMs) * 1_000_000)
        }

        try? await Task.sleep(nanoseconds: 3_000_000_000)

        let received = receivedTestPongs.count
        return PacketLossResult(
            sent: count,
            received: received,
            lostPercent: Double(count - received) / Double(count) * 100,
            durationSeconds: Date().timeIntervalSince(startTime)
        )
    }

    private func runLatencyUnderLoad(baselineAvg: Double) async -> LatencyUnderLoadResult {
        receivedTestPongs.removeAll()
        pendingTestPongs.removeAll()

        // Generate heavy load concurrently
        let loadTask = Task {
            for i in 0 ..< 800 {
                connectionManager.send(.throughputData(testID: UUID()))
                if i % 50 == 0 { sampleSystem() }
                try? await Task.sleep(nanoseconds: 12_000_000) // 12ms
            }
        }

        // Measure latency during load
        var seq = 0
        for i in 0 ..< 50 {
            let id = UUID()
            let timestamp = ProcessInfo.processInfo.systemUptime
            pendingTestPongs[id] = (sequence: seq, timestamp: timestamp)
            connectionManager.send(.testPing(id: id, sequence: seq, timestamp: timestamp))
            seq += 1
            phaseProgress = Double(i + 1) / 50.0
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        await loadTask.value
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        let rtts = receivedTestPongs.sorted(by: { $0.sequence < $1.sequence }).map(\.rtt)
        let underLoadAvg = rtts.isEmpty ? 0 : rtts.reduce(0, +) / Double(rtts.count)
        let degradation = baselineAvg > 0 ? ((underLoadAvg - baselineAvg) / baselineAvg) * 100 : 0

        return LatencyUnderLoadResult(
            baselineAvg: baselineAvg,
            underLoadAvg: underLoadAvg,
            degradationPercent: degradation,
            sampleCount: rtts.count
        )
    }

    private func runHeavyLoadStress() async -> HeavyLoadResult {
        receivedTestPongs.removeAll()
        pendingTestPongs.removeAll()
        let startTime = Date()
        var bytesSent = 0

        // 3 concurrent load generators + latency probing for 15 seconds
        let load1 = Task {
            for _ in 0 ..< 1000 {
                connectionManager.send(.throughputData(testID: UUID()))
                bytesSent += 32768
                try? await Task.sleep(nanoseconds: 15_000_000)
            }
        }
        let load2 = Task {
            for _ in 0 ..< 1000 {
                connectionManager.send(.throughputData(testID: UUID()))
                bytesSent += 32768
                try? await Task.sleep(nanoseconds: 15_000_000)
            }
        }
        let load3 = Task {
            for _ in 0 ..< 500 {
                connectionManager.send(.throughputData(testID: UUID()))
                bytesSent += 32768
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
        }

        // Ping while under maximum stress
        var seq = 0
        for i in 0 ..< 75 {
            let id = UUID()
            let timestamp = ProcessInfo.processInfo.systemUptime
            pendingTestPongs[id] = (sequence: seq, timestamp: timestamp)
            connectionManager.send(.testPing(id: id, sequence: seq, timestamp: timestamp))
            seq += 1
            phaseProgress = Double(i + 1) / 75.0
            if i % 10 == 0 { sampleSystem() }
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
        }

        await load1.value
        await load2.value
        await load3.value
        try? await Task.sleep(nanoseconds: 3_000_000_000)

        let rtts = receivedTestPongs.sorted(by: { $0.sequence < $1.sequence }).map(\.rtt)
        let avgLatency = rtts.isEmpty ? 0 : rtts.reduce(0, +) / Double(rtts.count)
        let maxLatency = rtts.max() ?? 0
        let elapsed = Date().timeIntervalSince(startTime)
        let loss = Double(seq - rtts.count) / Double(seq) * 100
        let throughput = Double(bytesSent) / max(elapsed, 0.001)

        return HeavyLoadResult(
            avgLatency: avgLatency,
            maxLatency: maxLatency,
            throughputBps: throughput,
            packetLoss: max(0, loss),
            sampleCount: rtts.count
        )
    }

    private func sampleSystem() {
        let snap = SystemMonitor.snapshot()
        cpuSamples.append(snap.cpuUsage)
        peakMemoryMB = max(peakMemoryMB, snap.memoryUsedMB)

        let thermalOrder = ["Nominal", "Fair", "Serious", "Critical"]
        let currentThermal = SystemMonitor.thermalStateString(snap.thermalState)
        if let currentIdx = thermalOrder.firstIndex(of: currentThermal),
           let worstIdx = thermalOrder.firstIndex(of: worstThermalState),
           currentIdx > worstIdx
        {
            worstThermalState = currentThermal
        }
    }

    // MARK: - Helpers

    private func buildLatencyResult(_ rtts: [Double]) -> LatencyBurstResult {
        guard !rtts.isEmpty else {
            return LatencyBurstResult(min: 0, max: 0, avg: 0, median: 0, p95: 0, sampleCount: 0, samples: [])
        }
        let sorted = rtts.sorted()
        let avg = sorted.reduce(0, +) / Double(sorted.count)
        let median = sorted[sorted.count / 2]
        let p95 = sorted[min(Int(Double(sorted.count) * 0.95), sorted.count - 1)]
        return LatencyBurstResult(
            min: sorted.first!,
            max: sorted.last!,
            avg: avg,
            median: median,
            p95: p95,
            sampleCount: sorted.count,
            samples: rtts
        )
    }

    private func buildRemoteDeviceInfo() -> DeviceInfo {
        DeviceInfo(
            name: metrics.peerDeviceName ?? "Unknown",
            model: metrics.peerModel ?? "Unknown",
            modelNumber: metrics.peerModelNumber ?? "",
            osVersion: metrics.peerOSVersion ?? "Unknown"
        )
    }

    private func buildLocalDeviceInfo() -> DeviceInfo {
        DeviceIdentifier.localDeviceInfo()
    }

    private func computeGrade(
        latency: LatencyBurstResult,
        jitter: JitterResult,
        loss: PacketLossResult,
        underLoad: LatencyUnderLoadResult
    ) -> SignalQuality {
        // No real data collected — test effectively failed
        if latency.sampleCount == 0, jitter.sampleCount == 0 {
            return .poor
        }

        var score = 0
        if latency.avg < 10 { score += 3 } else if latency.avg < 30 { score += 2 }
        else if latency.avg < 100 { score += 1 }
        if jitter.averageJitter < 5 { score += 3 } else if jitter.averageJitter < 15 { score += 2 }
        else if jitter.averageJitter < 30 { score += 1 }
        if loss.lostPercent < 1 { score += 3 } else if loss.lostPercent < 5 { score += 2 }
        else if loss.lostPercent < 10 { score += 1 }
        if underLoad.degradationPercent <= 0 { score += 3 } // improved or no change
        else if underLoad.degradationPercent < 50 { score += 2 }
        else if underLoad.degradationPercent < 100 { score += 1 }

        if score >= 9 { return .excellent }
        if score >= 6 { return .good }
        if score >= 3 { return .fair }
        return .poor
    }
}
