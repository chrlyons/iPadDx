import Foundation
import Network
import UIKit

enum TestPhase: String, CaseIterable {
    case dnsResolution = "DNS Resolution"
    case latencyBurst = "Latency Burst"
    case sustainedThroughput = "Throughput"
    case jitterMeasurement = "Jitter Stability"
    case packetLossStress = "Packet Loss Stress"
    case latencyUnderLoad = "Latency Under Load"
    case heavyLoad = "Heavy Load Stress"

    var icon: String {
        switch self {
        case .dnsResolution: "magnifyingglass.circle.fill"
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
        case .dnsResolution: "cyan"
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
        case .dnsResolution: "Measures mDNS/Bonjour name resolution time"
        case .latencyBurst: "100 rapid pings to measure round-trip time"
        case .sustainedThroughput: "10 MB real payload transfer, rate measured by the receiver"
        case .jitterMeasurement: "150 samples measuring latency variation"
        case .packetLossStress: "500 aggressive pings at 10ms intervals"
        case .latencyUnderLoad: "Latency while a real payload stream saturates the link"
        case .heavyLoad: "Concurrent data + pings for 15 seconds"
        }
    }

    var detailedDescription: String {
        switch self {
        case .dnsResolution:
            "Starts a fresh NWBrowser for _ipadconn._tcp and measures how long the peer's Bonjour service name takes to appear in browse results. This is mDNS discovery time only — it deliberately does not open a TCP/TLS connection, because doing so would disturb the peer's listener mid-test."
        case .latencyBurst:
            "Sends 100 ping-pong messages at 50ms intervals and measures the round-trip time for each. Reports min, max, average, median, and P95 latency. This is the baseline measurement of how fast data travels between the two devices over the local Wi-Fi network."
        case .sustainedThroughput:
            "Streams 10 MB of real payload in 32 KB chunks. The receiving device counts the bytes that actually arrive and reports how long they took, so the rate is measured at the far end rather than estimated by the sender. Important for apps that sync large files or stream content."
        case .jitterMeasurement:
            "Sends 150 ping-pong messages at 80ms intervals and measures how much the latency varies between consecutive samples. Low jitter means consistent, predictable performance. High jitter can cause lag spikes in real-time apps even when average latency is acceptable."
        case .packetLossStress:
            "Fires 500 pings at 10ms intervals — intentionally aggressive to stress the connection. Counts how many responses come back. Any packet loss indicates the network is being pushed beyond its reliable capacity, which can cause data retransmissions and timeouts."
        case .latencyUnderLoad:
            "Saturates the link with a continuous stream of real 32 KB payload chunks while measuring latency with 50 pings. Compares the under-load latency to the baseline burst. Shows how much real-world multitasking degrades connection responsiveness."
        case .heavyLoad:
            "Maximum stress test: 3 concurrent real-payload streams plus 75 latency probes for 15 seconds. Simulates worst-case usage where multiple operations compete for bandwidth. Measures latency, throughput, and packet loss under extreme conditions."
        }
    }

    var whyItMatters: String {
        switch self {
        case .dnsResolution:
            "Real Bonjour apps must discover a peer before they can connect to it, and that discovery step is invisible once a connection is already open. Slow mDNS discovery causes poor first-connect experiences."
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
        case .dnsResolution: config.runDNSResolution
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
    case failed(String) // why it failed
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
    var cancelRequested: Bool = false
    /// The peer's Bonjour service name for DNS resolution testing.
    var peerBonjourName: String?

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
    private let thermalTracker = SystemMonitor.ThermalTracker()
    /// Drives the background load generators used by the under-load phases.
    private var loadGeneratorActive = false
    /// Baselines so link conditions describe THIS run's window, not all time.
    private var linkPathChangesAtStart = 0
    private var linkDisconnectsAtStart = 0
    private var linkDiscoveryFlapsAtStart = 0
    /// In-flight throughput transfer awaiting the peer's measurement.
    /// Internal rather than private so tests can verify ack routing.
    private(set) var throughputTestID: UUID?
    private var throughputAckContinuation: CheckedContinuation<ThroughputAck?, Never>?
    private var throughputAckTimeout: Task<Void, Never>?
    /// An ack that arrived before the phase started waiting for it.
    /// Internal rather than private so tests can verify ack routing.
    private(set) var pendingThroughputAck: ThroughputAck?

    struct ThroughputAck {
        let bytesReceived: Int
        let duration: TimeInterval
    }

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
        // A previous run that was cancelled leaves state == .failed; that must not
        // block the next run.
        guard state != .running else { return nil }

        let cfg = config
        guard cfg.enabledPhaseCount > 0 else { return nil }

        SystemMonitor.enableBatteryMonitoring()
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "iPadDx test suite running"
        )
        suiteStartTime = Date()
        // Baselines for the link-conditions snapshot built at the end of the run.
        linkPathChangesAtStart = metrics.pathChangeCount
        linkDisconnectsAtStart = metrics.disconnectHistory.count
        linkDiscoveryFlapsAtStart = metrics.discoveryFlapCount
        batteryStart = SystemMonitor.batteryLevel()
        cpuSamples.removeAll()
        peakMemoryMB = 0
        worstThermalState = "Nominal"
        errorLog.removeAll()
        responderMetrics = nil
        cancelRequested = false
        progress = 0
        state = .running
        isWarmingUp = false
        thermalTracker.reset()

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

        // Results default to "not measured". A phase that is disabled or that
        // collects nothing leaves its zero-valued placeholder here, and computeGrade
        // deliberately excludes any dimension with no samples.
        var dnsResult: DNSResolutionResult?
        var latency = LatencyBurstResult(min: 0, max: 0, avg: 0, median: 0, p95: 0, sampleCount: 0, samples: [])
        var throughput = ThroughputResult(bytesPerSecond: 0, totalBytes: 0, durationSeconds: 0)
        var jitter = JitterResult(averageJitter: 0, maxJitter: 0, sampleCount: 0)
        var packetLoss = PacketLossResult(sent: 0, received: 0, lostPercent: 0, durationSeconds: 0)
        var underLoad = LatencyUnderLoadResult(baselineAvg: 0, underLoadAvg: 0, degradationPercent: 0, sampleCount: 0)
        var heavyLoad: HeavyLoadResult?

        // Single pass. `break` exits early on cancellation while keeping every result
        // gathered so far, so a cancelled run still produces a partial report.
        repeat {
            // A cancel during warm-up must stop before the first phase runs.
            if isCancelled {
                break
            }

            // Phase 0: DNS Resolution
            if cfg.runDNSResolution {
                let serviceName = peerBonjourName ?? metrics.peerDeviceName ?? "Unknown"
                let result = await runPhase(.dnsResolution) {
                    await self.runDNSResolutionTest(serviceName: serviceName)
                }
                dnsResult = result
                if result.resolved {
                    phaseStatuses[.dnsResolution] = .completed(String(format: "%.0fms", result.resolutionTimeMs))
                } else {
                    phaseStatuses[.dnsResolution] = .failed("Could not resolve '\(serviceName)'")
                    errorLog.append("DNS Resolution: failed to resolve '\(serviceName)'")
                }
                phaseIndex += 1
                progress = phaseIndex / totalPhases
                sampleSystem()
            }
            if isCancelled {
                break
            }

            // Phase 1: Latency Burst
            if cfg.runLatencyBurst {
                latency = await runPhase(.latencyBurst) {
                    await self.runLatencyBurst(count: cfg.latencyBurstCount, intervalMs: cfg.latencyBurstIntervalMs)
                }
                if latency.sampleCount == 0 {
                    errorLog
                        .append(
                            "Latency Burst: 0/\(cfg.latencyBurstCount) pongs received — remote may not be responding"
                        )
                    phaseStatuses[.latencyBurst] = .failed("No pongs received")
                } else {
                    if latency.sampleCount < cfg.latencyBurstCount / 2 {
                        errorLog
                            .append(
                                "Latency Burst: only \(latency.sampleCount)/\(cfg.latencyBurstCount) pongs received — significant packet loss"
                            )
                    }
                    phaseStatuses[.latencyBurst] =
                        .completed(
                            "Avg: \(String(format: "%.1fms", latency.avg)) | P95: \(String(format: "%.1fms", latency.p95))"
                        )
                }
                phaseIndex += 1
                progress = phaseIndex / totalPhases
                sampleSystem()
            }
            if isCancelled {
                break
            }

            // Phase 2: Sustained Throughput
            if cfg.runThroughput {
                throughput = await runPhase(.sustainedThroughput) {
                    await self.runThroughputTest(bytes: cfg.throughputBytes)
                }
                if throughput.bytesPerSecond > 0 {
                    phaseStatuses[.sustainedThroughput] = .completed(throughput.formattedSpeed)
                } else {
                    phaseStatuses[.sustainedThroughput] = .failed("Transfer not acknowledged")
                }
                phaseIndex += 1
                progress = phaseIndex / totalPhases
                sampleSystem()
            }
            if isCancelled {
                break
            }

            // Phase 3: Jitter
            if cfg.runJitter {
                jitter = await runPhase(.jitterMeasurement) {
                    await self.runJitterTest(count: cfg.jitterSampleCount, intervalMs: cfg.jitterIntervalMs)
                }
                if jitter.sampleCount == 0 {
                    errorLog
                        .append("Jitter: 0/\(cfg.jitterSampleCount) pongs received — remote not responding to pings")
                    phaseStatuses[.jitterMeasurement] = .failed("No pongs received")
                } else {
                    phaseStatuses[.jitterMeasurement] =
                        .completed(
                            "Avg: \(String(format: "%.1fms", jitter.averageJitter)) | Max: \(String(format: "%.1fms", jitter.maxJitter))"
                        )
                }
                phaseIndex += 1
                progress = phaseIndex / totalPhases
                sampleSystem()
            }
            if isCancelled {
                break
            }

            // Phase 4: Packet Loss Stress
            if cfg.runPacketLoss {
                packetLoss = await runPhase(.packetLossStress) {
                    await self.runPacketLossStress(count: cfg.packetLossCount, intervalMs: cfg.packetLossIntervalMs)
                }
                if packetLoss.received == 0 {
                    errorLog.append("Packet Loss: 0/\(packetLoss.sent) received — connection may be dead")
                    phaseStatuses[.packetLossStress] = .failed("No responses received")
                } else {
                    if packetLoss.lostPercent > 50 {
                        errorLog
                            .append(
                                "Packet Loss: \(String(format: "%.0f", packetLoss.lostPercent))% loss (\(packetLoss.received)/\(packetLoss.sent) received)"
                            )
                    }
                    phaseStatuses[.packetLossStress] =
                        .completed(
                            "Loss: \(String(format: "%.1f%%", packetLoss.lostPercent)) (\(packetLoss.received)/\(packetLoss.sent))"
                        )
                }
                phaseIndex += 1
                progress = phaseIndex / totalPhases
                sampleSystem()
            }
            if isCancelled {
                break
            }

            // Phase 5: Latency Under Load
            if cfg.runLatencyUnderLoad {
                underLoad = await runPhase(.latencyUnderLoad) {
                    await self.runLatencyUnderLoad(baselineAvg: latency.avg)
                }
                if underLoad.sampleCount == 0 {
                    errorLog.append("Latency Under Load: no pongs received while the link was loaded")
                    phaseStatuses[.latencyUnderLoad] = .failed("No pongs received")
                } else {
                    phaseStatuses[.latencyUnderLoad] = .completed(underLoad.formattedDegradation)
                }
                phaseIndex += 1
                progress = phaseIndex / totalPhases
                sampleSystem()
            }
            if isCancelled {
                break
            }

            // Phase 6: Heavy Load Stress
            if cfg.runHeavyLoad {
                let heavy = await runPhase(.heavyLoad) {
                    await self.runHeavyLoadStress()
                }
                heavyLoad = heavy
                if heavy.sampleCount == 0 {
                    errorLog.append("Heavy Load: no pongs received under maximum stress")
                    phaseStatuses[.heavyLoad] = .failed("No pongs received")
                } else {
                    phaseStatuses[.heavyLoad] =
                        .completed(
                            "Avg: \(String(format: "%.1fms", heavy.avgLatency)) | Loss: \(String(format: "%.1f%%", heavy.packetLoss))"
                        )
                }
                phaseIndex += 1
                sampleSystem()
            }
        } while false

        let wasCancelled = isCancelled
        if wasCancelled {
            for p in TestPhase.allCases where phaseStatuses[p] == .pending {
                phaseStatuses[p] = .skipped
            }
            errorLog.append("Test cancelled by user — this is a partial report")
        }

        progress = 1.0
        metrics.currentTestPhase = nil

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
            thermalStateDuringTest: worstThermalState,
            thermalTransitions: thermalTracker.transitions.isEmpty ? nil : thermalTracker.transitions
        )

        let link = buildLinkConditions()
        if link.pathChanges > 0 {
            errorLog.append(
                "Link changed \(link.pathChanges) time(s) during the test — results may not be comparable"
            )
        }
        if !link.disconnects.isEmpty {
            errorLog.append("Connection dropped \(link.disconnects.count) time(s) during the test")
        }
        if let flaps = link.discoveryFlaps, flaps > 0 {
            errorLog.append(
                "Peer vanished from Bonjour discovery \(flaps) time(s) during the test — discovery/radio instability"
            )
        }

        let remoteInfo = buildRemoteDeviceInfo()
        if remoteInfo.name == "Unknown" || remoteInfo.model == "Unknown" {
            errorLog.append("Peer info exchange failed — remote device is Unknown (peer info never received)")
        }

        // Signal test complete so responder sends its metrics
        connectionManager.send(.testSuiteStatus(running: false, phase: ""))

        // Wait briefly for responder metrics to arrive
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        // Anything disabled up front, plus anything cancellation cut short.
        var skipped = TestPhase.allCases.filter { !$0.isEnabled(in: cfg) }.map(\.rawValue)
        skipped.append(
            contentsOf: TestPhase.allCases
                .filter { phaseStatuses[$0] == .skipped && $0.isEnabled(in: cfg) }
                .map(\.rawValue)
        )
        let grade = computeGrade(latency: latency, jitter: jitter, loss: packetLoss, underLoad: underLoad)
        // A run that measured something but has no scored dimension (throughput-only,
        // say) is honestly ungraded rather than Poor.
        let gradeLabel = grade?.rawValue ?? TestSuiteResults.notGradedLabel

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
                overallGrade: gradeLabel,
                responderMetrics: responderMetrics,
                dnsResolution: dnsResult,
                heavyLoad: heavyLoad,
                linkConditions: link
            ),
            durationSeconds: Date().timeIntervalSince(suiteStartTime ?? Date()),
            errors: errorLog.isEmpty ? nil : errorLog,
            skippedPhases: skipped.isEmpty ? nil : skipped,
            // Always the transport the run actually used. There is no override:
            // labelling a report with a bridge that never carried the bytes is
            // exactly the kind of fabrication this project forbids.
            bridgeTransport: connectionManager.bridgeTransport
        )

        lastReport = report
        state = wasCancelled ? .failed("Cancelled by user") : .completed
        currentPhase = nil
        ProcessInfo.processInfo.endActivity(activity)
        return report
    }

    func cancel() {
        cancelRequested = true
        // Stop any in-flight load stream immediately rather than letting it run out.
        loadGeneratorActive = false
        // Release a phase that is blocked waiting for the peer's throughput ack.
        throughputAckTimeout?.cancel()
        throughputAckTimeout = nil
        if let pending = throughputAckContinuation {
            throughputAckContinuation = nil
            throughputTestID = nil
            pending.resume(returning: nil)
        }
        connectionManager.send(.testSuiteStatus(running: false, phase: ""))
    }

    private var isCancelled: Bool {
        cancelRequested
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
        cancelRequested = false
        loadGeneratorActive = false
        throughputAckTimeout?.cancel()
        throughputAckTimeout = nil
        throughputTestID = nil
        pendingThroughputAck = nil
    }

    // MARK: - Phase Runner

    private func runPhase<T>(_ phase: TestPhase, test: () async -> T) async -> T {
        currentPhase = phase
        // Attribute any latency anomaly raised during this phase to it.
        metrics.currentTestPhase = phase.rawValue
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
            if isCancelled {
                break
            }
            let id = UUID()
            let timestamp = ProcessInfo.processInfo.systemUptime
            pendingTestPongs[id] = (sequence: i, timestamp: timestamp)
            connectionManager.send(.testPing(id: id, sequence: i, timestamp: timestamp))
            try? await Task.sleep(nanoseconds: UInt64(intervalMs) * 1_000_000)
        }

        // Brief wait for remaining responses
        if !isCancelled {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        // Discard warm-up data
        receivedTestPongs.removeAll()
        pendingTestPongs.removeAll()
    }

    /// Round-trip times ordered by probe sequence number.
    private func orderedRTTs() -> [Double] {
        receivedTestPongs.sorted { $0.sequence < $1.sequence }.map(\.rtt)
    }

    // MARK: - DNS Resolution

    /// Measures mDNS resolution time using NWBrowser to discover the service name,
    /// without opening a TCP connection to the peer's listener (which would disrupt it).
    /// Measures how long the peer's Bonjour service takes to appear in a fresh browse.
    ///
    /// The browser MUST be configured exactly like the app's main browser
    /// (`BonjourService.startBrowsing`): `includePeerToPeer = true` and a nil domain.
    /// Without peer-to-peer the browser cannot see a peer reachable only over AWDL —
    /// i.e. a direct device-to-device link with no access point — and the phase reports
    /// "could not resolve" for a peer that is plainly connected.
    private func runDNSResolutionTest(serviceName: String) async -> DNSResolutionResult {
        let serviceType = "_ipadconn._tcp"
        let start = CFAbsoluteTimeGetCurrent()
        let seen = DiscoveredNames()

        let resolved = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let once = ResumeOnce(cont)
            let params = NWParameters()
            params.includePeerToPeer = true
            let browser = NWBrowser(
                for: .bonjour(type: serviceType, domain: nil),
                using: params
            )

            browser.browseResultsChangedHandler = { results, _ in
                for result in results {
                    guard case let .service(name, _, _, _) = result.endpoint else { continue }
                    seen.insert(name)
                    // mDNS renames on collision ("Pink" -> "Pink (2)"), and the peer's
                    // display name may not be its advertised service name, so accept an
                    // exact match or a conflict-renamed variant of it.
                    if name == serviceName || name.hasPrefix("\(serviceName) (") {
                        browser.cancel()
                        once.resume(true)
                        return
                    }
                }
            }

            browser.stateUpdateHandler = { state in
                if case .failed = state {
                    browser.cancel()
                    once.resume(false)
                }
            }

            browser.start(queue: .global(qos: .userInitiated))

            DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                browser.cancel()
                once.resume(false)
            }
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - start
        let names = seen.all()

        if !resolved {
            // Say what WAS visible. "Could not resolve X" on its own gives nothing to
            // act on; the list of advertised names usually identifies the problem
            // immediately (renamed service, wrong name source, nothing advertising).
            let found = names.isEmpty
                ? "no _ipadconn._tcp services were advertising"
                : "saw: \(names.sorted().joined(separator: ", "))"
            errorLog.append("DNS Resolution: '\(serviceName)' not found — \(found)")
        }

        return DNSResolutionResult(
            resolutionTimeMs: elapsed * 1000,
            resolved: resolved,
            serviceName: serviceName,
            discoveredNames: names.isEmpty ? nil : names.sorted()
        )
    }

    /// Thread-safe one-shot continuation resume. The browse handler, the state handler
    /// and the timeout all run on different queues; resuming twice traps.
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var cont: CheckedContinuation<Bool, Never>?

        init(_ cont: CheckedContinuation<Bool, Never>) {
            self.cont = cont
        }

        func resume(_ value: Bool) {
            lock.lock()
            let pending = cont
            cont = nil
            lock.unlock()
            pending?.resume(returning: value)
        }
    }

    /// Collects service names seen during the browse, from the browser's queue.
    private final class DiscoveredNames: @unchecked Sendable {
        private let lock = NSLock()
        private var names: Set<String> = []

        func insert(_ name: String) {
            lock.lock()
            names.insert(name)
            lock.unlock()
        }

        func all() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return Array(names)
        }
    }

    // MARK: - Test Phases

    private func runLatencyBurst(count: Int, intervalMs: Int) async -> LatencyBurstResult {
        receivedTestPongs.removeAll()
        pendingTestPongs.removeAll()

        for i in 0 ..< count {
            guard !isCancelled else { break }
            let id = UUID()
            let timestamp = ProcessInfo.processInfo.systemUptime
            pendingTestPongs[id] = (sequence: i, timestamp: timestamp)
            connectionManager.send(.testPing(id: id, sequence: i, timestamp: timestamp))
            phaseProgress = Double(i + 1) / Double(count)
            try? await Task.sleep(nanoseconds: UInt64(intervalMs) * 1_000_000)
        }

        if !isCancelled {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }

        return buildLatencyResult(orderedRTTs())
    }

    /// Transfers `bytes` of real payload to the peer and reports the rate the peer
    /// actually measured on receipt.
    ///
    /// Nothing here is estimated: the sender streams genuine bytes with per-chunk
    /// backpressure, and the returned rate comes from the peer's `throughputAck`
    /// (bytes it counted / time it took). If the peer never acks, the phase reports
    /// zero samples and is marked failed rather than inventing a number.
    private func runThroughputTest(bytes: Int) async -> ThroughputResult {
        let testID = UUID()
        beginThroughputTest(id: testID)
        // Await the start message: if a data chunk overtook it, the receiver would
        // discard the chunk as belonging to an unknown transfer.
        guard await connectionManager.sendAwaitingCompletion(
            .throughputStart(testID: testID, byteCount: bytes)
        ) else {
            throughputTestID = nil
            errorLog.append("Throughput: could not start the transfer — connection unavailable")
            return ThroughputResult(bytesPerSecond: 0, totalBytes: 0, durationSeconds: 0)
        }

        let sent = await DiagnosticEngine.sendThroughputPayload(
            over: connectionManager,
            testID: testID,
            byteCount: bytes,
            isCancelled: { [weak self] in self?.isCancelled ?? true },
            onProgress: { [weak self] fraction in self?.phaseProgress = fraction }
        )

        if isCancelled {
            throughputTestID = nil
            return ThroughputResult(bytesPerSecond: 0, totalBytes: 0, durationSeconds: 0)
        }

        if sent < bytes {
            errorLog.append(
                "Throughput: only \(sent)/\(bytes) bytes could be sent — connection dropped mid-transfer"
            )
        }

        // Wait for the peer's measurement. Timeout scales with transfer size so a
        // slow-but-working link isn't cut off.
        // Must exceed the receiver's 60s stall timeout so a slow-but-alive link gets the
        // chance to ack partial data instead of both sides giving up.
        let ackTimeout = max(75.0, Double(bytes) / 200_000.0)
        guard let ack = await awaitThroughputAck(timeout: ackTimeout) else {
            errorLog.append("Throughput: peer never acknowledged the transfer — no rate measured")
            return ThroughputResult(bytesPerSecond: 0, totalBytes: sent, durationSeconds: 0)
        }

        return ThroughputResult(
            bytesPerSecond: Double(ack.bytesReceived) / max(ack.duration, 0.001),
            totalBytes: ack.bytesReceived,
            durationSeconds: ack.duration
        )
    }

    /// Arms an in-flight transfer id. Used by `runThroughputTest`; exposed for tests
    /// that verify the ack is routed to the runner.
    func beginThroughputTest(id: UUID) {
        throughputTestID = id
        pendingThroughputAck = nil
    }

    /// Called by `DiagnosticEngine` when the peer reports what it received.
    func handleThroughputAck(testID: UUID, bytesReceived: Int, duration: TimeInterval) {
        guard testID == throughputTestID else { return }
        let ack = ThroughputAck(bytesReceived: bytesReceived, duration: duration)
        if let continuation = throughputAckContinuation {
            throughputTestID = nil
            throughputAckContinuation = nil
            throughputAckTimeout?.cancel()
            throughputAckTimeout = nil
            continuation.resume(returning: ack)
        } else {
            // The peer can finish measuring and ack while the sender is still inside the
            // final chunk's completion. Hold the measurement rather than dropping it.
            pendingThroughputAck = ack
        }
    }

    private func awaitThroughputAck(timeout: TimeInterval) async -> ThroughputAck? {
        if let early = pendingThroughputAck {
            pendingThroughputAck = nil
            throughputTestID = nil
            return early
        }
        let expectedID = throughputTestID
        return await withCheckedContinuation { (continuation: CheckedContinuation<ThroughputAck?, Never>) in
            throughputAckContinuation = continuation
            throughputAckTimeout = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                // Only fire for the wait this watchdog was created for — a stale timer
                // must never abort a later run's wait.
                guard throughputTestID == expectedID,
                      let pending = throughputAckContinuation else { return }
                throughputAckContinuation = nil
                throughputAckTimeout = nil
                throughputTestID = nil
                pending.resume(returning: nil)
            }
        }
    }

    private func runJitterTest(count: Int, intervalMs: Int) async -> JitterResult {
        receivedTestPongs.removeAll()
        pendingTestPongs.removeAll()

        for i in 0 ..< count {
            if isCancelled {
                break
            }
            let id = UUID()
            let timestamp = ProcessInfo.processInfo.systemUptime
            pendingTestPongs[id] = (sequence: i, timestamp: timestamp)
            connectionManager.send(.testPing(id: id, sequence: i, timestamp: timestamp))
            phaseProgress = Double(i + 1) / Double(count)
            try? await Task.sleep(nanoseconds: UInt64(intervalMs) * 1_000_000)
        }

        if !isCancelled {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }

        // Jitter is the variation between *consecutive* probes. Pongs that were lost
        // leave gaps in the sequence, so only compare samples whose sequence numbers
        // are genuinely adjacent — otherwise a dropped pong makes two probes that were
        // 160ms apart look consecutive and inflates the result.
        let ordered = receivedTestPongs.sorted { $0.sequence < $1.sequence }
        guard ordered.count >= 2 else {
            return JitterResult(averageJitter: 0, maxJitter: 0, sampleCount: ordered.count)
        }

        var diffs: [Double] = []
        for i in 1 ..< ordered.count where ordered[i].sequence == ordered[i - 1].sequence + 1 {
            diffs.append(abs(ordered[i].rtt - ordered[i - 1].rtt))
        }

        guard !diffs.isEmpty else {
            return JitterResult(averageJitter: 0, maxJitter: 0, sampleCount: ordered.count)
        }

        return JitterResult(
            averageJitter: diffs.reduce(0, +) / Double(diffs.count),
            maxJitter: diffs.max() ?? 0,
            sampleCount: ordered.count
        )
    }

    private func runPacketLossStress(count: Int, intervalMs: Int) async -> PacketLossResult {
        receivedTestPongs.removeAll()
        pendingTestPongs.removeAll()
        let startTime = Date()

        var sent = 0
        for i in 0 ..< count {
            if isCancelled {
                break
            }
            let id = UUID()
            let timestamp = ProcessInfo.processInfo.systemUptime
            pendingTestPongs[id] = (sequence: i, timestamp: timestamp)
            connectionManager.send(.testPing(id: id, sequence: i, timestamp: timestamp))
            sent += 1
            phaseProgress = Double(i + 1) / Double(count)
            try? await Task.sleep(nanoseconds: UInt64(intervalMs) * 1_000_000)
        }

        if !isCancelled {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }

        let received = receivedTestPongs.count
        return PacketLossResult(
            sent: sent,
            received: received,
            lostPercent: sent > 0 ? Double(sent - received) / Double(sent) * 100 : 0,
            durationSeconds: Date().timeIntervalSince(startTime)
        )
    }

    /// Saturates the link with real payload bytes while measuring latency.
    ///
    /// The load generator streams genuine 32 KB chunks as fast as the transport
    /// accepts them (per-chunk backpressure) and keeps running for the entire
    /// measurement window, rather than dribbling out a fixed number of empty frames.
    private func runLatencyUnderLoad(baselineAvg: Double) async -> LatencyUnderLoadResult {
        receivedTestPongs.removeAll()
        pendingTestPongs.removeAll()

        loadGeneratorActive = true
        let loadTask = startLoadGenerator(sampleEvery: 50)

        // Measure latency while the link is loaded
        var seq = 0
        for i in 0 ..< 50 {
            if isCancelled {
                break
            }
            let id = UUID()
            let timestamp = ProcessInfo.processInfo.systemUptime
            pendingTestPongs[id] = (sequence: seq, timestamp: timestamp)
            connectionManager.send(.testPing(id: id, sequence: seq, timestamp: timestamp))
            seq += 1
            phaseProgress = Double(i + 1) / 50.0
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        loadGeneratorActive = false
        await loadTask.value
        if !isCancelled {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }

        let rtts = orderedRTTs()
        let underLoadAvg = rtts.isEmpty ? 0 : rtts.reduce(0, +) / Double(rtts.count)
        // A phase that collected nothing is a failure, not an improvement. Leaving
        // degradation at 0 here would otherwise score the maximum in computeGrade.
        let degradation: Double = if rtts.isEmpty || baselineAvg <= 0 {
            0
        } else {
            ((underLoadAvg - baselineAvg) / baselineAvg) * 100
        }

        return LatencyUnderLoadResult(
            baselineAvg: baselineAvg,
            underLoadAvg: underLoadAvg,
            degradationPercent: degradation,
            sampleCount: rtts.count
        )
    }

    /// Streams real payload chunks until `loadGeneratorActive` is cleared.
    /// Returns the task so the caller can await a clean stop.
    private func startLoadGenerator(sampleEvery: Int) -> Task<Int, Never> {
        Task { @MainActor [weak self] in
            guard let self else { return 0 }
            // A fresh id the peer is not tracking: the bytes really cross the wire and
            // load the link, but they are not counted into any throughput measurement.
            let loadID = UUID()
            var bytesSent = 0
            var i = 0
            while loadGeneratorActive, !isCancelled {
                let queued = await connectionManager.sendAwaitingCompletion(
                    .throughputData(testID: loadID, payload: ThroughputPayload.sharedChunk)
                )
                if !queued {
                    break
                }
                bytesSent += ThroughputPayload.chunkSize
                i += 1
                if sampleEvery > 0, i % sampleEvery == 0 {
                    sampleSystem()
                }
            }
            return bytesSent
        }
    }

    private func runHeavyLoadStress() async -> HeavyLoadResult {
        receivedTestPongs.removeAll()
        pendingTestPongs.removeAll()
        let startTime = Date()

        // 3 concurrent real-payload load generators + latency probing for 15 seconds
        loadGeneratorActive = true
        let load1 = startLoadGenerator(sampleEvery: 0)
        let load2 = startLoadGenerator(sampleEvery: 0)
        let load3 = startLoadGenerator(sampleEvery: 0)

        // Ping while under maximum stress
        var seq = 0
        for i in 0 ..< 75 {
            if isCancelled {
                break
            }
            let id = UUID()
            let timestamp = ProcessInfo.processInfo.systemUptime
            pendingTestPongs[id] = (sequence: seq, timestamp: timestamp)
            connectionManager.send(.testPing(id: id, sequence: seq, timestamp: timestamp))
            seq += 1
            phaseProgress = Double(i + 1) / 75.0
            if i % 10 == 0 {
                sampleSystem()
            }
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
        }

        loadGeneratorActive = false
        let bytesSent = await load1.value + load2.value + load3.value
        // Measure the streaming window only — the drain wait below is idle time and
        // must not dilute the rate.
        let loadElapsed = Date().timeIntervalSince(startTime)
        if !isCancelled {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }

        let rtts = orderedRTTs()
        let avgLatency = rtts.isEmpty ? 0 : rtts.reduce(0, +) / Double(rtts.count)
        let maxLatency = rtts.max() ?? 0
        let loss = seq > 0 ? Double(seq - rtts.count) / Double(seq) * 100 : 0
        let throughput = Double(bytesSent) / max(loadElapsed, 0.001)

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
        thermalTracker.sample()

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
        return LatencyBurstResult(
            min: sorted.first!,
            max: sorted.last!,
            avg: avg,
            median: LatencyBurstResult.median(sorted),
            p95: LatencyBurstResult.percentile(sorted, 0.95),
            sampleCount: sorted.count,
            samples: rtts,
            p5: LatencyBurstResult.percentile(sorted, 0.05),
            p25: LatencyBurstResult.percentile(sorted, 0.25),
            p75: LatencyBurstResult.percentile(sorted, 0.75),
            p99: LatencyBurstResult.percentile(sorted, 0.99),
            histogram: LatencyBurstResult.buildHistogram(samples: rtts),
            anomalyCount: LatencyBurstResult.anomalyCount(in: rtts)
        )
    }

    /// Snapshots the network path this run actually used.
    private func buildLinkConditions() -> LinkConditions {
        let newDisconnects = metrics.disconnectHistory
            .dropFirst(linkDisconnectsAtStart)
            .map {
                LinkDisconnect(
                    timestamp: $0.timestamp,
                    reason: $0.reason.rawValue,
                    detail: $0.detail
                )
            }
        return LinkConditions(
            interfaceName: metrics.interfaceName,
            interfaceType: metrics.interfaceTypeString,
            usedPeerToPeer: metrics.usesPeerToPeerLink,
            pathStatus: String(describing: metrics.pathStatus),
            isExpensive: metrics.isExpensive,
            isConstrained: metrics.isConstrained,
            ssid: metrics.peerSSID,
            bssid: metrics.peerBSSID,
            pathChanges: max(0, metrics.pathChangeCount - linkPathChangesAtStart),
            disconnects: Array(newDisconnects),
            discoveryFlaps: max(0, metrics.discoveryFlapCount - linkDiscoveryFlapsAtStart)
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

    /// The overall grade, or nil when no scored dimension produced samples.
    private func computeGrade(
        latency: LatencyBurstResult,
        jitter: JitterResult,
        loss: PacketLossResult,
        underLoad: LatencyUnderLoadResult
    ) -> SignalQuality? {
        // Poor means measured-and-bad. A run with no SCORED dimension is not gradeable
        // at all — the 12-point scale covers latency, jitter, packet loss and load
        // degradation, so a throughput-only run has nothing to score and must not be
        // branded Poor for it. Returning nil lets the report say "Not graded".
        let hasScorableDimension = latency.sampleCount > 0 || jitter.sampleCount > 0
            || loss.sent > 0 || underLoad.sampleCount > 0
        guard hasScorableDimension else { return nil }

        // Only dimensions that actually produced measurements may contribute.
        // Zero sits in the best-scoring band of every dimension, so scoring a
        // disabled or empty phase would make skipping work *raise* the grade.
        var earned = 0
        var possible = 0

        if latency.sampleCount > 0 {
            possible += 3
            if latency.avg < 10 {
                earned += 3
            } else if latency.avg < 30 {
                earned += 2
            } else if latency.avg < 100 {
                earned += 1
            }
        }
        if jitter.sampleCount > 0 {
            possible += 3
            if jitter.averageJitter < 5 {
                earned += 3
            } else if jitter.averageJitter < 15 {
                earned += 2
            } else if jitter.averageJitter < 30 {
                earned += 1
            }
        }
        if loss.sent > 0 {
            possible += 3
            if loss.lostPercent < 1 {
                earned += 3
            } else if loss.lostPercent < 5 {
                earned += 2
            } else if loss.lostPercent < 10 {
                earned += 1
            }
        }
        // Degradation is only meaningful against a real baseline; without one the
        // computed 0 would silently score the maximum.
        if underLoad.sampleCount > 0, underLoad.baselineAvg > 0 {
            possible += 3
            if underLoad.degradationPercent <= 0 {
                earned += 3
            } // improved or no change
            else if underLoad.degradationPercent < 50 {
                earned += 2
            } else if underLoad.degradationPercent < 100 {
                earned += 1
            }
        }

        guard possible > 0 else { return nil }

        // Normalise back onto the documented 12-point scale so the published bands
        // stay meaningful however many phases ran.
        let score = Double(earned) / Double(possible) * 12.0
        if score >= 9 {
            return .excellent
        }
        if score >= 6 {
            return .good
        }
        if score >= 3 {
            return .fair
        }
        return .poor
    }
}
