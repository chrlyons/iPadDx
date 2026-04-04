import XCTest
@testable import iPadDx

final class TestReportTests: XCTestCase {

    // MARK: - Helpers

    private func makeReport(
        bridgeTransport: String? = "native",
        errors: [String]? = nil,
        skippedPhases: [String]? = nil
    ) -> TestReport {
        TestReport(
            id: UUID(),
            date: Date(),
            localDevice: DeviceInfo(name: "iPad A", model: "iPad Pro 13-inch (M4)", modelNumber: "iPad16,5", osVersion: "18.4"),
            remoteDevice: DeviceInfo(name: "iPad B", model: "iPad mini (6th gen)", modelNumber: "iPad14,1", osVersion: "17.5"),
            results: makeSuiteResults(),
            durationSeconds: 45.0,
            errors: errors,
            skippedPhases: skippedPhases,
            bridgeTransport: bridgeTransport
        )
    }

    private func makeSuiteResults() -> TestSuiteResults {
        TestSuiteResults(
            latencyBurst: LatencyBurstResult(min: 2.0, max: 15.0, avg: 5.5, median: 4.8, p95: 12.0, sampleCount: 100, samples: [2.0, 5.0, 15.0]),
            sustainedThroughput: ThroughputResult(bytesPerSecond: 5_000_000, totalBytes: 10_000_000, durationSeconds: 2.0),
            jitterMeasurement: JitterResult(averageJitter: 3.2, maxJitter: 8.5, sampleCount: 150),
            packetLossStress: PacketLossResult(sent: 500, received: 498, lostPercent: 0.4, durationSeconds: 5.0),
            latencyUnderLoad: LatencyUnderLoadResult(baselineAvg: 5.0, underLoadAvg: 12.0, degradationPercent: 140.0, sampleCount: 50),
            systemMetrics: SystemMetricsResult(
                batteryStart: 0.85, batteryEnd: 0.83, batteryDrainPercent: 2.0,
                peakCpuUsage: 45.0, avgCpuUsage: 25.0, peakMemoryMB: 128.0,
                thermalStateDuringTest: "Nominal"
            ),
            overallGrade: "Good"
        )
    }

    // MARK: - Round-trip

    func testReportRoundTrip() throws {
        let report = makeReport(bridgeTransport: "cordova", errors: ["timeout"], skippedPhases: ["heavyLoad"])
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(TestReport.self, from: data)

        XCTAssertEqual(decoded.id, report.id)
        XCTAssertEqual(decoded.bridgeTransport, "cordova")
        XCTAssertEqual(decoded.errors, ["timeout"])
        XCTAssertEqual(decoded.skippedPhases, ["heavyLoad"])
        XCTAssertEqual(decoded.results.overallGrade, "Good")
        XCTAssertEqual(decoded.results.latencyBurst.sampleCount, 100)
    }

    // MARK: - Backward compatibility

    func testDecodingWithoutBridgeTransport() throws {
        // Simulate a report from before bridgeTransport was added
        let report = makeReport(bridgeTransport: "native")
        var data = try JSONEncoder().encode(report)

        // Remove bridgeTransport key from JSON
        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        json.removeValue(forKey: "bridgeTransport")
        data = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(TestReport.self, from: data)
        XCTAssertNil(decoded.bridgeTransport, "Missing bridgeTransport should decode as nil")
    }

    func testDecodingWithoutErrorsAndSkippedPhases() throws {
        let report = makeReport()
        var data = try JSONEncoder().encode(report)

        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        json.removeValue(forKey: "errors")
        json.removeValue(forKey: "skippedPhases")
        data = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(TestReport.self, from: data)
        XCTAssertNil(decoded.errors)
        XCTAssertNil(decoded.skippedPhases)
    }

    func testDecodingWithoutResponderMetrics() throws {
        let report = makeReport()
        var data = try JSONEncoder().encode(report)

        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        if var results = json["results"] as? [String: Any] {
            results.removeValue(forKey: "responderMetrics")
            json["results"] = results
        }
        data = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(TestReport.self, from: data)
        XCTAssertNil(decoded.results.responderMetrics)
    }

    // MARK: - DeviceInfo

    func testDeviceInfoEquality() {
        let a = DeviceInfo(name: "iPad A", model: "iPad Pro", modelNumber: "iPad16,5", osVersion: "18.4")
        let b = DeviceInfo(name: "iPad A", model: "iPad Pro", modelNumber: "iPad16,5", osVersion: "18.4")
        let c = DeviceInfo(name: "iPad B", model: "iPad Pro", modelNumber: "iPad16,5", osVersion: "18.4")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testDeviceInfoBackwardCompatMissingModelNumber() throws {
        let info = DeviceInfo(name: "iPad", model: "iPad Pro", modelNumber: "iPad16,5", osVersion: "18.0")
        var data = try JSONEncoder().encode(info)

        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        json.removeValue(forKey: "modelNumber")
        data = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(DeviceInfo.self, from: data)
        XCTAssertEqual(decoded.modelNumber, "", "Missing modelNumber should default to empty string")
    }

    func testDeviceInfoDisplayModel() {
        let normal = DeviceInfo(name: "A", model: "iPad Pro 13-inch (M4)", modelNumber: "iPad16,5", osVersion: "18.0")
        XCTAssertEqual(normal.displayModel, "iPad Pro 13-inch (M4)")

        let unknown = DeviceInfo(name: "A", model: "Unknown", modelNumber: "iPad16,5", osVersion: "18.0")
        XCTAssertEqual(unknown.displayModel, "iPad16,5")

        let empty = DeviceInfo(name: "A", model: "", modelNumber: "iPad16,5", osVersion: "18.0")
        XCTAssertEqual(empty.displayModel, "iPad16,5")
    }

    // MARK: - Result formatting

    func testThroughputFormattedSpeed() {
        let mbps = ThroughputResult(bytesPerSecond: 5_000_000, totalBytes: 10_000_000, durationSeconds: 2.0)
        XCTAssertEqual(mbps.formattedSpeed, "5.0 MB/s")

        let kbps = ThroughputResult(bytesPerSecond: 50_000, totalBytes: 100_000, durationSeconds: 2.0)
        XCTAssertEqual(kbps.formattedSpeed, "50.0 KB/s")

        let bps = ThroughputResult(bytesPerSecond: 500, totalBytes: 1000, durationSeconds: 2.0)
        XCTAssertEqual(bps.formattedSpeed, "500 B/s")
    }

    func testJitterQualityLabel() {
        XCTAssertEqual(JitterResult(averageJitter: 2.0, maxJitter: 5.0, sampleCount: 50).qualityLabel, "Stable")
        XCTAssertEqual(JitterResult(averageJitter: 10.0, maxJitter: 20.0, sampleCount: 50).qualityLabel, "Moderate")
        XCTAssertEqual(JitterResult(averageJitter: 20.0, maxJitter: 40.0, sampleCount: 50).qualityLabel, "Unstable")
        XCTAssertEqual(JitterResult(averageJitter: 50.0, maxJitter: 100.0, sampleCount: 50).qualityLabel, "Very Unstable")
    }

    func testLatencyUnderLoadDegradation() {
        let worse = LatencyUnderLoadResult(baselineAvg: 5.0, underLoadAvg: 12.0, degradationPercent: 140.0, sampleCount: 50)
        XCTAssertTrue(worse.formattedDegradation.contains("worse"))

        let improved = LatencyUnderLoadResult(baselineAvg: 5.0, underLoadAvg: 4.0, degradationPercent: -20.0, sampleCount: 50)
        XCTAssertTrue(improved.formattedDegradation.contains("improved"))

        let same = LatencyUnderLoadResult(baselineAvg: 5.0, underLoadAvg: 5.0, degradationPercent: 0, sampleCount: 50)
        XCTAssertTrue(same.formattedDegradation.contains("no change"))
    }
}
