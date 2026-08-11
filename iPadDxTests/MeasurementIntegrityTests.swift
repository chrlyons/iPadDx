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
    private func results(
        latencySamples: Int,
        latencyAvg: Double,
        jitterSamples: Int,
        jitterAvg: Double,
        lossSent: Int,
        lossPercent: Double,
        throughput: Double,
        underLoadSamples: Int,
        baseline: Double,
        degradation: Double
    ) -> TestSuiteResults {
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
        results(
            latencySamples: 100,
            latencyAvg: 10,
            jitterSamples: 150,
            jitterAvg: 3,
            lossSent: 500,
            lossPercent: 2,
            throughput: 5_000_000,
            underLoadSamples: 50,
            baseline: 10,
            degradation: 50
        )
    }

    /// A cancelled run: exactly the all-zero placeholder TestSuiteRunner persists.
    private var unmeasured: TestSuiteResults {
        results(
            latencySamples: 0,
            latencyAvg: 0,
            jitterSamples: 0,
            jitterAvg: 0,
            lossSent: 0,
            lossPercent: 0,
            throughput: 0,
            underLoadSamples: 0,
            baseline: 0,
            degradation: 0
        )
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
        let r = results(
            latencySamples: 100,
            latencyAvg: 10,
            jitterSamples: 150,
            jitterAvg: 3,
            lossSent: 500,
            lossPercent: 2,
            throughput: 1,
            underLoadSamples: 50,
            baseline: 0,
            degradation: 50
        )
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

/// Guards the *breakdown* aggregations, not just the overview.
///
/// The first pass at this fix only filtered the overview rows; per-pair, per-chip,
/// per-OS, per-bridge and trend paths still averaged raw fields, so one real 10ms run
/// plus two cancelled placeholder reports still read as 3.3ms in those comparisons.
final class SummaryValidityTests: XCTestCase {
    private func summary(
        id: UUID = UUID(),
        latencySamples: Int, latencyAvg: Double,
        jitterSamples: Int = 0, jitterAvg: Double = 0,
        lossSent: Int = 0, lossPercent: Double = 0,
        throughput: Double = 0,
        loadSamples: Int = 0, loadBaseline: Double = 0, degradation: Double = 0
    ) -> ReportSummary {
        ReportSummary(
            id: id, date: Date(), durationSeconds: 1, overallGrade: "Good", source: "local",
            localName: "A", localModel: "iPad", localModelNumber: "iPad16,3",
            localOS: "18.0", localChip: "M4",
            remoteName: "B", remoteModel: "iPad", remoteModelNumber: "iPad15,7",
            remoteOS: "18.0", remoteChip: "A16",
            latencyMin: latencyAvg, latencyMax: latencyAvg, latencyAvg: latencyAvg,
            latencyMedian: latencyAvg, latencyP95: latencyAvg, latencySampleCount: latencySamples,
            throughputBps: throughput, throughputBytes: 0, throughputDuration: 0,
            jitterAvg: jitterAvg, jitterMax: jitterAvg, jitterSampleCount: jitterSamples,
            packetLossSent: lossSent, packetLossReceived: lossSent, packetLossPercent: lossPercent,
            packetLossDuration: 1,
            loadBaselineAvg: loadBaseline, loadUnderLoadAvg: 20,
            loadDegradation: degradation, loadSampleCount: loadSamples,
            bridgeTransport: "native",
            usedPeerToPeer: false, linkChanges: 0, linkDisconnects: 0, discoveryFlaps: 0
        )
    }

    func testMeasuredSummaryExposesValues() {
        let s = summary(
            latencySamples: 100, latencyAvg: 10,
            jitterSamples: 150, jitterAvg: 3,
            lossSent: 500, lossPercent: 2,
            throughput: 5_000_000,
            loadSamples: 50, loadBaseline: 10, degradation: 40
        )
        XCTAssertEqual(s.measuredLatencyAvg, 10)
        XCTAssertEqual(s.measuredJitter, 3)
        XCTAssertEqual(s.measuredPacketLoss, 2)
        XCTAssertEqual(s.measuredThroughput, 5_000_000)
        XCTAssertEqual(s.measuredLoadDegradation, 40)
    }

    func testCancelledSummaryExposesNil() {
        let s = summary(latencySamples: 0, latencyAvg: 0)
        XCTAssertNil(s.measuredLatencyAvg)
        XCTAssertNil(s.measuredJitter)
        XCTAssertNil(s.measuredPacketLoss)
        XCTAssertNil(s.measuredThroughput)
        XCTAssertNil(s.measuredLoadDegradation)
    }

    func testLoadDegradationRequiresSamplesAndABaseline() {
        // Samples but no baseline: the percentage is not comparable to anything.
        let noBaseline = summary(
            latencySamples: 100,
            latencyAvg: 10,
            loadSamples: 50,
            loadBaseline: 0,
            degradation: 75
        )
        XCTAssertNil(noBaseline.measuredLoadDegradation)

        // Baseline but no samples: nothing was measured under load.
        let noSamples = summary(
            latencySamples: 100,
            latencyAvg: 10,
            loadSamples: 0,
            loadBaseline: 10,
            degradation: 75
        )
        XCTAssertNil(noSamples.measuredLoadDegradation)
    }

    func testPerPairStyleAverageIgnoresPlaceholders() {
        // Exactly the reviewer's scenario: one real 10ms run plus two cancelled runs.
        let group = [
            summary(latencySamples: 100, latencyAvg: 10),
            summary(latencySamples: 0, latencyAvg: 0),
            summary(latencySamples: 0, latencyAvg: 0),
        ]
        let measured = group.compactMap(\.measuredLatencyAvg)
        XCTAssertEqual(measured.count, 1)
        XCTAssertEqual(measuredMean(measured) ?? 0, 10, accuracy: 0.0001)

        let naive = group.map(\.latencyAvg).reduce(0, +) / Double(group.count)
        XCTAssertEqual(naive, 10.0 / 3.0, accuracy: 0.0001, "the old behaviour, for contrast")
    }

    func testGroupWithNoMeasurementsYieldsNilNotZero() {
        let group = [
            summary(latencySamples: 0, latencyAvg: 0),
            summary(latencySamples: 0, latencyAvg: 0),
        ]
        XCTAssertNil(measuredMean(group.compactMap(\.measuredLatencyAvg)))
    }
}

/// Trends must be fitted over measured points only.
///
/// A regression across a placeholder invents a slope: one measured 10ms report plus
/// two cancelled ones regressed over (10, 0, 0) reports a dramatic improvement that
/// never happened. TrendAnalyzer is fed date/value pairs, so the filtering has to
/// happen at every call site that builds those samples.
final class TrendSampleValidityTests: XCTestCase {
    private func dated(_ values: [Double], from start: Date = Date(timeIntervalSince1970: 1_700_000_000))
        -> [(date: Date, value: Double)]
    {
        values.enumerated().map { (date: start.addingTimeInterval(Double($0.offset) * 86400), value: $0.element) }
    }

    func testRegressionOverPlaceholdersFabricatesATrend() {
        // Demonstrates the bug being guarded against: 10, 0, 0 looks like a steep
        // improvement in a lower-is-better metric.
        let fabricated = TrendAnalyzer.analyzeTrend(
            samples: dated([10, 0, 0]),
            metric: "Avg Latency", lowerIsBetter: true, period: "3 reports"
        )
        XCTAssertNotNil(fabricated, "sanity: a regression over placeholders does produce a result")
        XCTAssertFalse(fabricated?.isFlat ?? true, "and it is not flat — it is a fake trend")
    }

    func testFilteringToMeasuredPointsRefusesToTrendASingleReport() {
        // After filtering, only one real point remains — not enough to regress, so no
        // trend is reported at all.
        let measuredOnly = dated([10])
        XCTAssertNil(
            TrendAnalyzer.analyzeTrend(
                samples: measuredOnly,
                metric: "Avg Latency", lowerIsBetter: true, period: "1 report"
            ),
            "a single measured point must not yield a trend"
        )
    }

    func testGenuineTrendStillReported() {
        let trend = TrendAnalyzer.analyzeTrend(
            samples: dated([30, 20, 10]),
            metric: "Avg Latency", lowerIsBetter: true, period: "3 reports"
        )
        XCTAssertNotNil(trend)
        XCTAssertFalse(trend?.isFlat ?? true)
    }

    func testFlatDataIsNotReportedAsAConfidentTrend() {
        let trend = TrendAnalyzer.analyzeTrend(
            samples: dated([10, 10, 10]),
            metric: "Avg Latency", lowerIsBetter: true, period: "3 reports"
        )
        // Identical samples have undefined R-squared; confidence must not be maxed.
        if let trend, !trend.isFlat {
            XCTAssertLessThan(trend.confidence, 1.0)
        }
    }
}

/// Per-report presentation must not show a placeholder as a measurement.
///
/// Aggregation was fixed first, but a single cancelled report rendered "0.00ms" in
/// the summary CSV, the side-by-side comparison and the post-run cards — where zero
/// reads as the *best* result, not as missing data.
final class PhaseGroupValidityTests: XCTestCase {
    private func results(
        latencySamples: Int,
        throughput: Double,
        jitterSamples: Int,
        lossSent: Int,
        loadSamples: Int,
        baseline: Double
    ) -> TestSuiteResults {
        TestSuiteResults(
            latencyBurst: LatencyBurstResult(
                min: 1, max: 2, avg: 1.5, median: 1.5, p95: 2,
                sampleCount: latencySamples, samples: []
            ),
            sustainedThroughput: ThroughputResult(
                bytesPerSecond: throughput, totalBytes: 10, durationSeconds: 1
            ),
            jitterMeasurement: JitterResult(averageJitter: 1, maxJitter: 2, sampleCount: jitterSamples),
            packetLossStress: PacketLossResult(
                sent: lossSent, received: lossSent, lostPercent: 1, durationSeconds: 1
            ),
            latencyUnderLoad: LatencyUnderLoadResult(
                baselineAvg: baseline, underLoadAvg: 5,
                degradationPercent: 10, sampleCount: loadSamples
            ),
            systemMetrics: SystemMetricsResult(
                batteryStart: 1, batteryEnd: 1, batteryDrainPercent: 0,
                peakCpuUsage: 1, avgCpuUsage: 1, peakMemoryMB: 1,
                thermalStateDuringTest: "Nominal"
            ),
            overallGrade: "Good"
        )
    }

    /// Every phase flag must be independent — one measured phase must not make the
    /// others look measured, which is what a single report-level flag would do.
    func testPhaseValidityFlagsAreIndependent() {
        let onlyLatency = results(
            latencySamples: 100,
            throughput: 0,
            jitterSamples: 0,
            lossSent: 0,
            loadSamples: 0,
            baseline: 0
        )
        XCTAssertTrue(onlyLatency.hasLatency)
        XCTAssertFalse(onlyLatency.hasThroughput)
        XCTAssertFalse(onlyLatency.hasJitter)
        XCTAssertFalse(onlyLatency.hasPacketLoss)
        XCTAssertFalse(onlyLatency.hasLoadDegradation)

        let onlyThroughput = results(
            latencySamples: 0,
            throughput: 1000,
            jitterSamples: 0,
            lossSent: 0,
            loadSamples: 0,
            baseline: 0
        )
        XCTAssertFalse(onlyThroughput.hasLatency)
        XCTAssertTrue(onlyThroughput.hasThroughput)
    }

    func testFullyMeasuredRunHasEveryFlag() {
        let all = results(
            latencySamples: 100,
            throughput: 1000,
            jitterSamples: 150,
            lossSent: 500,
            loadSamples: 50,
            baseline: 10
        )
        XCTAssertTrue(all.hasLatency)
        XCTAssertTrue(all.hasThroughput)
        XCTAssertTrue(all.hasJitter)
        XCTAssertTrue(all.hasPacketLoss)
        XCTAssertTrue(all.hasLoadDegradation)
    }

    func testCancelledRunHasNoFlags() {
        let none = results(
            latencySamples: 0,
            throughput: 0,
            jitterSamples: 0,
            lossSent: 0,
            loadSamples: 0,
            baseline: 0
        )
        XCTAssertFalse(none.hasLatency)
        XCTAssertFalse(none.hasThroughput)
        XCTAssertFalse(none.hasJitter)
        XCTAssertFalse(none.hasPacketLoss)
        XCTAssertFalse(none.hasLoadDegradation)
    }
}

/// Guards the analytics trend inputs.
///
/// `computeTrends` and the OS breakdown were the last two places regressing over — and
/// rendering — raw summary columns. A cancelled run stores zeros, so one real 10ms
/// report plus two cancelled rows fitted a confident "improving" latency trend, and an
/// OS bucket with no measurements displayed a real-looking 0.0ms bar.
final class AnalyticsTrendInputTests: XCTestCase {
    private func sample(_ value: Double, day: Int) -> (date: Date, value: Double) {
        (date: Date(timeIntervalSince1970: 1_700_000_000 + Double(day) * 86400), value: value)
    }

    func testPlaceholderZerosWouldFabricateAnImprovingTrend() {
        // The exact reported scenario, showing why filtering is required.
        let unfiltered = TrendAnalyzer.analyzeTrend(
            samples: [sample(10, day: 0), sample(0, day: 1), sample(0, day: 2)],
            metric: "Latency Avg", lowerIsBetter: true, period: "3 reports"
        )
        XCTAssertNotNil(unfiltered)
        XCTAssertFalse(unfiltered?.isFlat ?? true, "regressing over placeholders invents a slope")
    }

    func testFilteringLeavesTooFewPointsToTrend() {
        // After compact-mapping measured values only one real point survives.
        XCTAssertNil(
            TrendAnalyzer.analyzeTrend(
                samples: [sample(10, day: 0)],
                metric: "Latency Avg", lowerIsBetter: true, period: "1 report"
            )
        )
    }

    func testPeriodDescribesOnlyTheMeasuredWindow() {
        // The badge must not claim a window wider than the points it was fitted over.
        let measured = [sample(30, day: 10), sample(20, day: 11), sample(10, day: 12)]
        let period = TrendAnalyzer.describePeriod(dates: measured.map(\.date))
        let wider = TrendAnalyzer.describePeriod(
            dates: [sample(0, day: 0).date] + measured.map(\.date)
        )
        XCTAssertNotEqual(period, wider, "period must reflect the measured samples, not all reports")
    }
}

/// Guards the bridge-overhead comparison.
///
/// This is the screen that states "Average round-trip latency measured…", so a zero
/// there is read as a measurement of an extremely fast bridge. Collapsing "nothing
/// measured" to 0 at the aggregation boundary put exactly that on screen.
final class BridgeComparisonValidityTests: XCTestCase {
    func testRowMetricsAreOptionalSoNotMeasuredCannotBecomeZero() {
        let row = BridgeComparisonRow(
            bridge: "cordova",
            reportCount: 3,
            measuredLatencyCount: 0,
            avgLatency: nil,
            avgJitter: nil,
            avgPacketLoss: nil,
            avgThroughput: nil,
            avgGradeScore: 0
        )
        XCTAssertNil(row.avgLatency, "not measured must not be representable as 0.0 ms")
        XCTAssertNil(row.avgJitter)
        XCTAssertNil(row.avgPacketLoss)
        XCTAssertNil(row.avgThroughput)
    }

    func testMeasuredCountIsSeparateFromReportCount() {
        // Three reports filed under a bridge, only one of which measured latency:
        // the displayed average is over 1, and the UI must be able to say so.
        let row = BridgeComparisonRow(
            bridge: "flutter",
            reportCount: 3,
            measuredLatencyCount: 1,
            avgLatency: 12.5,
            avgJitter: nil,
            avgPacketLoss: nil,
            avgThroughput: nil,
            avgGradeScore: 8
        )
        XCTAssertEqual(row.reportCount, 3)
        XCTAssertEqual(row.measuredLatencyCount, 1)
        XCTAssertEqual(row.avgLatency, 12.5)
    }

    func testGradeScoreMappingUnchanged() {
        // Band midpoints on the 12-point scale, not 0-based: Poor is 3, and an
        // unrecognised grade is the only thing that scores 0.
        XCTAssertEqual(BridgeComparisonRow.gradeScore("Excellent"), 12)
        XCTAssertEqual(BridgeComparisonRow.gradeScore("Good"), 9)
        XCTAssertEqual(BridgeComparisonRow.gradeScore("Fair"), 6)
        XCTAssertEqual(BridgeComparisonRow.gradeScore("Poor"), 3)
        XCTAssertEqual(BridgeComparisonRow.gradeScore("Cancelled"), 0)
    }
}

/// Guards the bridge-comparison pair selection.
///
/// Once bridgeComparison started dropping unmeasured rows, picking the "best" pair from
/// raw summaries first became wrong: a pair with many cancelled reports won the ranking,
/// produced zero rows, and the screen said "No bridge measurements recorded yet" while a
/// different pair had perfectly good data. Candidates must be ranked on measured rows.
final class BridgeComparisonSelectionTests: XCTestCase {
    private func row(_ bridge: String, latency: Double?, measured: Int) -> BridgeComparisonRow {
        BridgeComparisonRow(
            bridge: bridge,
            reportCount: max(measured, 1),
            measuredLatencyCount: measured,
            avgLatency: latency,
            avgJitter: nil,
            avgPacketLoss: nil,
            avgThroughput: nil,
            avgGradeScore: 9
        )
    }

    /// Mirrors the view's ranking: most bridges compared, then most measured reports.
    private func best(_ candidates: [(label: String, rows: [BridgeComparisonRow])])
        -> (label: String, rows: [BridgeComparisonRow])?
    {
        candidates
            .filter { !$0.rows.isEmpty }
            .max { lhs, rhs in
                let l = (lhs.rows.count, lhs.rows.reduce(0) { $0 + $1.measuredLatencyCount })
                let r = (rhs.rows.count, rhs.rows.reduce(0) { $0 + $1.measuredLatencyCount })
                if l != r {
                    return l < r
                }
                return lhs.label > rhs.label
            }
    }

    func testPairWithNoMeasuredRowsDoesNotHideAPairThatHasThem() {
        // "A→B" would win on raw report count but contributes no measured rows.
        let candidates = [
            (label: "A→B", rows: [BridgeComparisonRow]()),
            (label: "C→D", rows: [
                row("native", latency: 8, measured: 2),
                row("cordova", latency: 17, measured: 2),
            ]),
        ]
        let chosen = best(candidates)
        XCTAssertEqual(chosen?.label, "C→D", "an unmeasured pair must not suppress a measured one")
        XCTAssertEqual(chosen?.rows.count, 2)
    }

    func testAllPairsUnmeasuredYieldsNoComparison() {
        let candidates = [
            (label: "A→B", rows: [BridgeComparisonRow]()),
            (label: "C→D", rows: [BridgeComparisonRow]()),
        ]
        XCTAssertNil(best(candidates), "only then should the empty state appear")
    }

    func testMoreBridgesComparedWinsOverMoreReports() {
        let candidates = [
            (label: "A→B", rows: [row("native", latency: 8, measured: 50)]),
            (label: "C→D", rows: [
                row("native", latency: 8, measured: 2),
                row("flutter", latency: 14, measured: 2),
            ]),
        ]
        XCTAssertEqual(best(candidates)?.label, "C→D", "a comparison needs at least two bridges")
    }

    func testSelectionIsStableForEquallyGoodPairs() {
        let rows = [row("native", latency: 8, measured: 2), row("cordova", latency: 15, measured: 2)]
        let a = best([(label: "A→B", rows: rows), (label: "C→D", rows: rows)])
        let b = best([(label: "C→D", rows: rows), (label: "A→B", rows: rows)])
        XCTAssertEqual(a?.label, b?.label, "the screen must not flip between pairs on redraw")
    }
}

/// Guards against latency being treated as the only real metric.
///
/// Phases are independently disableable, so "no latency" does not mean "failed run".
/// Three places assumed otherwise: the PDF trend gate, the Failed Tests lists in both
/// exports, and computeGrade's short-circuit to Poor.
final class LatencyIsNotTheOnlyMetricTests: XCTestCase {
    private func results(latency: Int, jitter: Int, lossSent: Int, throughput: Double) -> TestSuiteResults {
        TestSuiteResults(
            latencyBurst: LatencyBurstResult(
                min: 1, max: 2, avg: 1.5, median: 1.5, p95: 2,
                sampleCount: latency, samples: []
            ),
            sustainedThroughput: ThroughputResult(
                bytesPerSecond: throughput, totalBytes: 10, durationSeconds: 1
            ),
            jitterMeasurement: JitterResult(averageJitter: 1, maxJitter: 2, sampleCount: jitter),
            packetLossStress: PacketLossResult(
                sent: lossSent, received: lossSent, lostPercent: 0.5, durationSeconds: 1
            ),
            latencyUnderLoad: LatencyUnderLoadResult(
                baselineAvg: 0, underLoadAvg: 0, degradationPercent: 0, sampleCount: 0
            ),
            systemMetrics: SystemMetricsResult(
                batteryStart: 1, batteryEnd: 1, batteryDrainPercent: 0,
                peakCpuUsage: 1, avgCpuUsage: 1, peakMemoryMB: 1,
                thermalStateDuringTest: "Nominal"
            ),
            overallGrade: "Good"
        )
    }

    func testRunWithoutLatencyIsNotAFailedRun() {
        // Latency Burst disabled, everything else measured cleanly.
        let r = results(latency: 0, jitter: 150, lossSent: 500, throughput: 5_000_000)
        XCTAssertFalse(r.measuredNothing, "a run is only failed when it measured nothing at all")
        XCTAssertFalse(r.hasLatency)
        XCTAssertTrue(r.hasJitter)
        XCTAssertTrue(r.hasPacketLoss)
        XCTAssertTrue(r.hasThroughput)
    }

    func testRunWithOnlyThroughputIsStillNotFailed() {
        let r = results(latency: 0, jitter: 0, lossSent: 0, throughput: 5_000_000)
        XCTAssertFalse(r.measuredNothing)
    }

    func testCancelledRunMeasuredNothing() {
        let r = results(latency: 0, jitter: 0, lossSent: 0, throughput: 0)
        XCTAssertTrue(r.measuredNothing)
    }

    func testMeasuredNothingRequiresEveryDimensionEmpty() {
        // Each dimension alone is enough to make the run non-failed.
        XCTAssertFalse(results(latency: 1, jitter: 0, lossSent: 0, throughput: 0).measuredNothing)
        XCTAssertFalse(results(latency: 0, jitter: 1, lossSent: 0, throughput: 0).measuredNothing)
        XCTAssertFalse(results(latency: 0, jitter: 0, lossSent: 1, throughput: 0).measuredNothing)
        XCTAssertFalse(results(latency: 0, jitter: 0, lossSent: 0, throughput: 1).measuredNothing)
    }
}
