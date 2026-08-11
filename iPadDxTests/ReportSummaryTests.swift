import XCTest
@testable import iPadDx

final class ReportSummaryTests: XCTestCase {
    private func makeReport(bridgeTransport: String? = "native") -> TestReport {
        TestReport(
            id: UUID(),
            date: Date(),
            localDevice: DeviceInfo(
                name: "iPad A",
                model: "iPad Pro 13-inch (M4)",
                modelNumber: "iPad16,5",
                osVersion: "18.4"
            ),
            remoteDevice: DeviceInfo(
                name: "iPad B",
                model: "iPad mini (6th gen)",
                modelNumber: "iPad14,1",
                osVersion: "17.5"
            ),
            results: TestSuiteResults(
                latencyBurst: LatencyBurstResult(
                    min: 2.0,
                    max: 15.0,
                    avg: 5.5,
                    median: 4.8,
                    p95: 12.0,
                    sampleCount: 100,
                    samples: []
                ),
                sustainedThroughput: ThroughputResult(
                    bytesPerSecond: 5_000_000,
                    totalBytes: 10_000_000,
                    durationSeconds: 2.0
                ),
                jitterMeasurement: JitterResult(averageJitter: 3.2, maxJitter: 8.5, sampleCount: 150),
                packetLossStress: PacketLossResult(sent: 500, received: 498, lostPercent: 0.4, durationSeconds: 5.0),
                latencyUnderLoad: LatencyUnderLoadResult(
                    baselineAvg: 5.0,
                    underLoadAvg: 12.0,
                    degradationPercent: 140.0,
                    sampleCount: 50
                ),
                systemMetrics: SystemMetricsResult(
                    batteryStart: 0.85, batteryEnd: 0.83, batteryDrainPercent: 2.0,
                    peakCpuUsage: 45.0, avgCpuUsage: 25.0, peakMemoryMB: 128.0,
                    thermalStateDuringTest: "Nominal"
                ),
                overallGrade: "Good"
            ),
            durationSeconds: 45.0,
            bridgeTransport: bridgeTransport
        )
    }

    // MARK: - Summary from TestReport

    func testSummaryFromReport() {
        let report = makeReport(bridgeTransport: "cordova")
        let summary = ReportSummary(from: report)

        XCTAssertEqual(summary.id, report.id)
        XCTAssertEqual(summary.overallGrade, "Good")
        XCTAssertEqual(summary.bridgeTransport, "cordova")
        XCTAssertEqual(summary.localName, "iPad A")
        XCTAssertEqual(summary.remoteName, "iPad B")
        XCTAssertEqual(summary.localChip, "M4")
        XCTAssertEqual(summary.remoteChip, "A15")
        XCTAssertEqual(summary.latencyAvg, 5.5)
        XCTAssertEqual(summary.throughputBps, 5_000_000)
        XCTAssertEqual(summary.jitterAvg, 3.2)
        XCTAssertEqual(summary.packetLossPercent, 0.4)
    }

    func testSummaryNilBridgeDefaultsToNative() {
        let report = makeReport(bridgeTransport: nil)
        let summary = ReportSummary(from: report)
        XCTAssertEqual(summary.bridgeTransport, "native")
    }

    // MARK: - Display helpers

    func testPairLabel() {
        let summary = ReportSummary(from: makeReport())
        XCTAssertEqual(summary.pairLabel, "M4 vs A15")
    }

    func testDisplayModelNormal() {
        let summary = ReportSummary(from: makeReport())
        XCTAssertEqual(summary.localDisplayModel, "iPad Pro 13-inch (M4)")
        XCTAssertEqual(summary.remoteDisplayModel, "iPad mini (6th gen)")
    }

    // MARK: - BridgeComparisonRow

    func testGradeScore() {
        XCTAssertEqual(BridgeComparisonRow.gradeScore("Excellent"), 12)
        XCTAssertEqual(BridgeComparisonRow.gradeScore("Good"), 9)
        XCTAssertEqual(BridgeComparisonRow.gradeScore("Fair"), 6)
        XCTAssertEqual(BridgeComparisonRow.gradeScore("Poor"), 3)
        // nil, not 0: 0 ranked an ungraded run BELOW Poor (3), so a bridge whose runs
        // were ungraded averaged worse than one genuinely measured as Poor.
        XCTAssertNil(BridgeComparisonRow.gradeScore("Unknown"))
        XCTAssertNil(BridgeComparisonRow.gradeScore(TestSuiteResults.notGradedLabel))
    }
}
