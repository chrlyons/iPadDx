import XCTest
@testable import iPadDx

/// Regression tests for the measurement-integrity fixes: the statistics helpers,
/// the throughput payload, and the grading rule that absent dimensions must not
/// score points.
final class MeasurementIntegrityTests: XCTestCase {
    // MARK: - Throughput payload

    func testThroughputMessageCarriesRealBytes() throws {
        let payload = ThroughputPayload.chunk(ofSize: ThroughputPayload.chunkSize)
        XCTAssertEqual(payload.count, ThroughputPayload.chunkSize)

        let message = DiagnosticMessage.throughputData(testID: UUID(), payload: payload)
        let frame = try message.encode()

        // The frame must actually be large enough to contain the payload. Before the
        // fix the message had no payload field at all and encoded to ~72 bytes while
        // being counted as a 32 KB chunk.
        XCTAssertGreaterThan(frame.count, ThroughputPayload.chunkSize)
    }

    func testThroughputPayloadRoundTripsIntact() throws {
        let sent = ThroughputPayload.chunk(ofSize: 4096)
        let frame = try DiagnosticMessage.throughputData(testID: UUID(), payload: sent).encode()

        // Strip the 4-byte length prefix that encode() prepends.
        let body = frame.dropFirst(4)
        let decoded = try DiagnosticMessage.decode(from: Data(body))

        guard case let .throughputData(_, received) = decoded else {
            return XCTFail("Expected throughputData, got \(decoded)")
        }
        XCTAssertEqual(received, sent)
    }

    func testThroughputPayloadIsNotAllZeroes() {
        // Zero-filled buffers can be optimised away by compressing layers, which would
        // make the measurement meaningless.
        let chunk = ThroughputPayload.chunk(ofSize: 1024)
        XCTAssertFalse(chunk.allSatisfy { $0 == 0 })
    }

    func testPartialChunkIsExactlyRequestedSize() {
        XCTAssertEqual(ThroughputPayload.chunk(ofSize: 100).count, 100)
        XCTAssertEqual(ThroughputPayload.chunk(ofSize: 0).count, 0)
        XCTAssertEqual(ThroughputPayload.chunk(ofSize: 70000).count, 70000)
    }

    // MARK: - Statistics

    func testMedianAveragesTwoCentralValuesWhenEven() {
        XCTAssertEqual(LatencyBurstResult.median([1, 2, 3, 4]), 2.5, accuracy: 0.0001)
        XCTAssertEqual(LatencyBurstResult.median([1, 2, 3]), 2.0, accuracy: 0.0001)
        XCTAssertEqual(LatencyBurstResult.median([]), 0.0, accuracy: 0.0001)
    }

    func testPercentileUsesInterpolationNotOffByOneIndex() {
        let sorted = (1 ... 100).map(Double.init)
        // The old form returned sorted[Int(100 * 0.95)] == 96. Correct p95 over
        // 1...100 is 95.05.
        XCTAssertEqual(LatencyBurstResult.percentile(sorted, 0.95), 95.05, accuracy: 0.01)
        XCTAssertEqual(LatencyBurstResult.percentile(sorted, 0.0), 1.0, accuracy: 0.0001)
        XCTAssertEqual(LatencyBurstResult.percentile(sorted, 1.0), 100.0, accuracy: 0.0001)
    }

    func testPercentileHandlesSingleAndEmptySamples() {
        XCTAssertEqual(LatencyBurstResult.percentile([], 0.95), 0.0, accuracy: 0.0001)
        XCTAssertEqual(LatencyBurstResult.percentile([7.0], 0.95), 7.0, accuracy: 0.0001)
    }

    func testAnomalyCountFlagsOutliersAndNeedsEnoughData() {
        XCTAssertNil(LatencyBurstResult.anomalyCount(in: [1, 2, 3]), "too few samples to be meaningful")

        var samples = Array(repeating: 10.0, count: 30)
        samples.append(contentsOf: [11.0, 9.0, 10.5, 9.5])
        samples.append(500.0) // unmistakable outlier
        let count = LatencyBurstResult.anomalyCount(in: samples)
        XCTAssertNotNil(count)
        XCTAssertGreaterThanOrEqual(count ?? 0, 1)
    }

    // MARK: - Report model

    func testHeavyLoadResultSurvivesRoundTrip() throws {
        let heavy = HeavyLoadResult(
            avgLatency: 22.5, maxLatency: 90.0, throughputBps: 4_000_000,
            packetLoss: 1.5, sampleCount: 75
        )
        let results = TestSuiteResults(
            latencyBurst: LatencyBurstResult(
                min: 1,
                max: 2,
                avg: 1.5,
                median: 1.5,
                p95: 2,
                sampleCount: 10,
                samples: [1, 2]
            ),
            sustainedThroughput: ThroughputResult(bytesPerSecond: 1000, totalBytes: 1000, durationSeconds: 1),
            jitterMeasurement: JitterResult(averageJitter: 1, maxJitter: 2, sampleCount: 10),
            packetLossStress: PacketLossResult(sent: 10, received: 10, lostPercent: 0, durationSeconds: 1),
            latencyUnderLoad: LatencyUnderLoadResult(
                baselineAvg: 1,
                underLoadAvg: 1,
                degradationPercent: 0,
                sampleCount: 10
            ),
            systemMetrics: SystemMetricsResult(
                batteryStart: 1, batteryEnd: 1, batteryDrainPercent: 0,
                peakCpuUsage: 1, avgCpuUsage: 1, peakMemoryMB: 1,
                thermalStateDuringTest: "Nominal"
            ),
            overallGrade: "Good",
            heavyLoad: heavy
        )

        let data = try JSONEncoder().encode(results)
        let decoded = try JSONDecoder().decode(TestSuiteResults.self, from: data)

        XCTAssertEqual(decoded.heavyLoad?.sampleCount, 75)
        XCTAssertEqual(decoded.heavyLoad?.avgLatency ?? 0, 22.5, accuracy: 0.0001)
    }

    func testResultsDecodeWithoutHeavyLoadForOlderReports() throws {
        // Reports written before Phase 6 was persisted must still load.
        let json = """
        {
          "latencyBurst": {"min":1,"max":2,"avg":1.5,"median":1.5,"p95":2,"sampleCount":10,"samples":[1,2]},
          "sustainedThroughput": {"bytesPerSecond":1000,"totalBytes":1000,"durationSeconds":1},
          "jitterMeasurement": {"averageJitter":1,"maxJitter":2,"sampleCount":10},
          "packetLossStress": {"sent":10,"received":10,"lostPercent":0,"durationSeconds":1},
          "latencyUnderLoad": {"baselineAvg":1,"underLoadAvg":1,"degradationPercent":0,"sampleCount":10},
          "systemMetrics": {"batteryStart":1,"batteryEnd":1,"batteryDrainPercent":0,"peakCpuUsage":1,"avgCpuUsage":1,"peakMemoryMB":1,"thermalStateDuringTest":"Nominal"},
          "overallGrade": "Good"
        }
        """
        let decoded = try JSONDecoder().decode(TestSuiteResults.self, from: Data(json.utf8))
        XCTAssertNil(decoded.heavyLoad)
        XCTAssertEqual(decoded.overallGrade, "Good")
    }
}

/// Regression tests for throughput ack routing.
///
/// The suite's throughput phase and the dashboard's manual test are two independent
/// senders, each filtering acks on its own id. Gating the forward to the runner on the
/// *engine's* id silently starved the suite phase: every report's throughput came back
/// as an unmeasured 0. These tests pin the routing down.
@MainActor
final class ThroughputAckRoutingTests: XCTestCase {
    private func encodedBody(_ message: DiagnosticMessage) throws -> Data {
        let frame = try message.encode()
        return Data(frame.dropFirst(4)) // strip the 4-byte length prefix
    }

    func testEngineForwardsAckToRunnerEvenWhenEngineHasNoTestOfItsOwn() throws {
        let manager = ConnectionManager(label: "routing-test")
        let metrics = DiagnosticMetrics()
        let engine = DiagnosticEngine(connectionManager: manager, metrics: metrics)
        let runner = TestSuiteRunner(connectionManager: manager, metrics: metrics)
        engine.testSuiteRunner = runner

        // The suite has a transfer in flight; the engine's own dashboard test does not.
        let suiteTestID = UUID()
        runner.beginThroughputTest(id: suiteTestID)

        let body = try encodedBody(
            .throughputAck(testID: suiteTestID, bytesReceived: 10_000_000, duration: 4.0)
        )
        engine.handleMessage(body)

        let ack = try XCTUnwrap(
            runner.pendingThroughputAck,
            "the suite's ack must reach the runner even though the engine has no test of its own"
        )
        XCTAssertEqual(ack.bytesReceived, 10_000_000)
        XCTAssertEqual(ack.duration, 4.0, accuracy: 0.0001)
    }

    func testRunnerIgnoresAckForADifferentTransfer() throws {
        let manager = ConnectionManager(label: "routing-test")
        let metrics = DiagnosticMetrics()
        let engine = DiagnosticEngine(connectionManager: manager, metrics: metrics)
        let runner = TestSuiteRunner(connectionManager: manager, metrics: metrics)
        engine.testSuiteRunner = runner

        runner.beginThroughputTest(id: UUID())
        let body = try encodedBody(
            .throughputAck(testID: UUID(), bytesReceived: 999, duration: 1.0)
        )
        engine.handleMessage(body)

        XCTAssertNil(runner.pendingThroughputAck, "an ack for another transfer must be ignored")
    }

    func testAckWithZeroDurationIsRejectedRatherThanProducingInfiniteRate() throws {
        let manager = ConnectionManager(label: "routing-test")
        let metrics = DiagnosticMetrics()
        let engine = DiagnosticEngine(connectionManager: manager, metrics: metrics)
        let runner = TestSuiteRunner(connectionManager: manager, metrics: metrics)
        engine.testSuiteRunner = runner

        let id = UUID()
        runner.beginThroughputTest(id: id)
        try engine.handleMessage(encodedBody(.throughputAck(testID: id, bytesReceived: 100, duration: 0)))
        XCTAssertNil(runner.pendingThroughputAck)

        try engine.handleMessage(encodedBody(.throughputAck(testID: id, bytesReceived: 0, duration: 5)))
        XCTAssertNil(runner.pendingThroughputAck)
    }
}

/// Tests for link-condition capture.
///
/// The question these exist to serve: was a run a DIRECT device-to-device radio link
/// (AWDL, no access point), or did it still hop through a local AP? Neither involves
/// the internet, and `NWInterface.type` reports `.wifi` for both, so the interface
/// name is the only thing that separates them.
final class LinkConditionsTests: XCTestCase {
    private func conditions(
        interfaceName: String?,
        changes: Int = 0,
        disconnects: [LinkDisconnect] = []
    ) -> LinkConditions {
        LinkConditions(
            interfaceName: interfaceName,
            interfaceType: "Wi-Fi",
            usedPeerToPeer: interfaceName?.hasPrefix("awdl") ?? false,
            pathStatus: "satisfied",
            isExpensive: false,
            isConstrained: false,
            ssid: "TestNet",
            bssid: nil,
            pathChanges: changes,
            disconnects: disconnects,
            discoveryFlaps: 0
        )
    }

    func testAwdlInterfaceIsReportedAsDirectDeviceToDevice() {
        let link = conditions(interfaceName: "awdl0")
        XCTAssertTrue(link.usedPeerToPeer)
        XCTAssertTrue(link.summary.contains("Direct device-to-device"))
        XCTAssertTrue(link.summary.contains("awdl0"))
    }

    func testAccessPointInterfaceIsNotReportedAsDirect() {
        let link = conditions(interfaceName: "en0")
        XCTAssertFalse(link.usedPeerToPeer)
        XCTAssertTrue(link.summary.contains("access point"))
        // Must never imply the internet was involved — both forms are local.
        XCTAssertFalse(link.summary.lowercased().contains("internet"))
    }

    func testLinkConditionsSurviveEncodingRoundTrip() throws {
        let link = conditions(
            interfaceName: "awdl0",
            changes: 2,
            disconnects: [LinkDisconnect(timestamp: Date(), reason: "pathChanged", detail: "POSIX ENETDOWN")]
        )
        let decoded = try JSONDecoder().decode(
            LinkConditions.self,
            from: JSONEncoder().encode(link)
        )
        XCTAssertTrue(decoded.usedPeerToPeer)
        XCTAssertEqual(decoded.pathChanges, 2)
        XCTAssertEqual(decoded.disconnects.count, 1)
        XCTAssertEqual(decoded.disconnects.first?.reason, "pathChanged")
        XCTAssertEqual(decoded.ssid, "TestNet")
    }

    func testOlderReportsWithoutLinkConditionsStillDecode() throws {
        let json = """
        {
          "latencyBurst": {"min":1,"max":2,"avg":1.5,"median":1.5,"p95":2,"sampleCount":10,"samples":[1,2]},
          "sustainedThroughput": {"bytesPerSecond":1000,"totalBytes":1000,"durationSeconds":1},
          "jitterMeasurement": {"averageJitter":1,"maxJitter":2,"sampleCount":10},
          "packetLossStress": {"sent":10,"received":10,"lostPercent":0,"durationSeconds":1},
          "latencyUnderLoad": {"baselineAvg":1,"underLoadAvg":1,"degradationPercent":0,"sampleCount":10},
          "systemMetrics": {"batteryStart":1,"batteryEnd":1,"batteryDrainPercent":0,"peakCpuUsage":1,"avgCpuUsage":1,"peakMemoryMB":1,"thermalStateDuringTest":"Nominal"},
          "overallGrade": "Good"
        }
        """
        let decoded = try JSONDecoder().decode(TestSuiteResults.self, from: Data(json.utf8))
        XCTAssertNil(decoded.linkConditions)
    }
}

/// Tests for latency chart windowing and downsampling.
///
/// The chart previously showed only ~60s because history was capped at 120 samples.
/// History is now retained for an hour and downsampled for rendering — and the
/// downsampling MUST keep peaks, or the spikes the chart exists to show disappear.
final class LatencyWindowTests: XCTestCase {

    private func samples(_ values: [Double], start: Date = Date()) -> [LatencySample] {
        values.enumerated().map { index, value in
            LatencySample(
                id: index,
                value: value,
                timestamp: start.addingTimeInterval(Double(index) * 0.5)
            )
        }
    }

    func testDownsamplePreservesPeaks() {
        // One large spike buried among low values must survive reduction.
        var values = Array(repeating: 10.0, count: 999)
        values[500] = 950.0
        let reduced = LatencyWindow.downsample(samples(values), to: 100)

        XCTAssertLessThanOrEqual(reduced.count, 101)
        XCTAssertTrue(
            reduced.contains { $0.value == 950.0 },
            "downsampling dropped the spike — the chart would hide the anomaly"
        )
    }

    func testDownsampleLeavesSmallSeriesUntouched() {
        let input = samples([1, 2, 3, 4])
        let reduced = LatencyWindow.downsample(input, to: 400)
        XCTAssertEqual(reduced.count, 4)
        XCTAssertEqual(reduced.map(\.value), [1, 2, 3, 4])
    }

    func testDownsampleKeepsChronologicalOrder() {
        let reduced = LatencyWindow.downsample(samples((0 ..< 1000).map(Double.init)), to: 50)
        XCTAssertEqual(reduced.map(\.id), reduced.map(\.id).sorted())
    }

    func testAllWindowKeepsEverything() {
        let input = samples(Array(repeating: 5.0, count: 300))
        XCTAssertEqual(LatencyWindow.all.filter(input).count, 300)
    }

    func testOneMinuteWindowKeepsOnlyRecentSamples() {
        // 0.5s cadence: 600 samples spans 300s. The last minute is ~120 samples.
        let input = samples(Array(repeating: 5.0, count: 600))
        let windowed = LatencyWindow.oneMinute.filter(input)
        XCTAssertGreaterThan(windowed.count, 100)
        XCTAssertLessThanOrEqual(windowed.count, 125)
        XCTAssertEqual(windowed.last?.id, input.last?.id, "must keep the most recent sample")
    }

    func testHistoryRetentionCoversALongSoak() {
        // An hour at the 500ms heartbeat. The old 120-sample cap held ~60 seconds.
        XCTAssertGreaterThanOrEqual(DiagnosticMetrics.defaultLatencyHistory, 7200)
    }
}

/// Guards against unmeasured zero placeholders being treated as real measurements.
///
/// Cancelled and disabled phases persist zeros, and since cancelled runs now produce
/// partial reports those zeros reach the store. Zero is a plausible-looking latency,
/// jitter, loss and throughput, so any aggregate that averages raw fields is dragged
/// toward zero by runs that measured nothing.
final class MeasurementValidityTests: XCTestCase {

    /// `latencyAvg` etc. are passed explicitly so the "unmeasured" fixture is exactly
    /// what TestSuiteRunner persists for a skipped or cancelled phase: zero counts AND
    /// zero values. Keeping non-zero values with zero counts would make the test pass
    /// for the wrong reason.
    private func results(latencySamples: Int, latencyAvg: Double,
                         jitterSamples: Int, jitterAvg: Double,
                         lossSent: Int, lossPercent: Double,
                         throughput: Double,
                         underLoadSamples: Int, baseline: Double,
                         degradation: Double) -> TestSuiteResults {
        TestSuiteResults(
            latencyBurst: LatencyBurstResult(
                min: latencyAvg, max: latencyAvg, avg: latencyAvg,
                median: latencyAvg, p95: latencyAvg,
                sampleCount: latencySamples, samples: []
            ),
            sustainedThroughput: ThroughputResult(
                bytesPerSecond: throughput, totalBytes: 100, durationSeconds: 1
            ),
            jitterMeasurement: JitterResult(
                averageJitter: jitterAvg, maxJitter: jitterAvg, sampleCount: jitterSamples
            ),
            packetLossStress: PacketLossResult(
                sent: lossSent, received: lossSent, lostPercent: lossPercent, durationSeconds: 1
            ),
            latencyUnderLoad: LatencyUnderLoadResult(
                baselineAvg: baseline, underLoadAvg: 20,
                degradationPercent: degradation, sampleCount: underLoadSamples
            ),
            systemMetrics: SystemMetricsResult(
                batteryStart: 1, batteryEnd: 1, batteryDrainPercent: 0,
                peakCpuUsage: 1, avgCpuUsage: 1, peakMemoryMB: 1,
                thermalStateDuringTest: "Nominal"
            ),
            overallGrade: "Good"
        )
    }

    private var measured: TestSuiteResults {
        results(latencySamples: 100, latencyAvg: 10,
                jitterSamples: 150, jitterAvg: 3,
                lossSent: 500, lossPercent: 2,
                throughput: 5_000_000,
                underLoadSamples: 50, baseline: 10, degradation: 50)
    }

    /// A cancelled run: exactly the all-zero placeholder TestSuiteRunner persists.
    private var unmeasured: TestSuiteResults {
        results(latencySamples: 0, latencyAvg: 0,
                jitterSamples: 0, jitterAvg: 0,
                lossSent: 0, lossPercent: 0,
                throughput: 0,
                underLoadSamples: 0, baseline: 0, degradation: 0)
    }

    func testMeasuredResultsExposeTheirValues() {
        let r = measured
        XCTAssertEqual(r.measuredLatencyAvg, 10)
        XCTAssertEqual(r.measuredJitter, 3)
        XCTAssertEqual(r.measuredPacketLoss, 2)
        XCTAssertEqual(r.measuredThroughput, 5_000_000)
        XCTAssertEqual(r.measuredLoadDegradation, 50)
    }

    func testUnmeasuredResultsExposeNilNotZero() {
        let r = unmeasured
        XCTAssertNil(r.measuredLatencyAvg, "zero latency from a cancelled phase is not a measurement")
        XCTAssertNil(r.measuredJitter)
        XCTAssertNil(r.measuredPacketLoss)
        XCTAssertNil(r.measuredThroughput)
        XCTAssertNil(r.measuredLoadDegradation)
    }

    func testLoadDegradationNeedsARealBaseline() {
        // Samples collected but no baseline: degradation is not comparable.
        let r = results(latencySamples: 100, latencyAvg: 10,
                        jitterSamples: 150, jitterAvg: 3,
                        lossSent: 500, lossPercent: 2,
                        throughput: 1,
                        underLoadSamples: 50, baseline: 0, degradation: 50)
        XCTAssertNil(r.measuredLoadDegradation)
    }

    func testAggregatingIgnoresUnmeasuredReports() {
        // One good run at 10ms plus two cancelled runs must average 10ms, not 3.3ms.
        let all = [measured, unmeasured, unmeasured]
        let values = all.compactMap(\.measuredLatencyAvg)
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values.reduce(0, +) / Double(values.count), 10, accuracy: 0.0001)

        // What the old code did: average the raw field across all three reports.
        let naive = all.map(\.latencyBurst.avg).reduce(0, +) / Double(all.count)
        XCTAssertEqual(naive, 10.0 / 3.0, accuracy: 0.0001)
        XCTAssertLessThan(naive, 5, "the naive average really is dragged toward zero")
    }
}
