import XCTest
@testable import iPadDx

final class TestSuiteConfigTests: XCTestCase {

    // MARK: - Defaults

    func testDefaultConfigValues() {
        let config = TestSuiteConfig.default
        XCTAssertTrue(config.runLatencyBurst)
        XCTAssertTrue(config.runThroughput)
        XCTAssertTrue(config.runJitter)
        XCTAssertTrue(config.runPacketLoss)
        XCTAssertTrue(config.runLatencyUnderLoad)
        XCTAssertTrue(config.runHeavyLoad)
        XCTAssertTrue(config.runWarmUp)
        XCTAssertEqual(config.bridgeTransports, ["native"])
    }

    func testDefaultEnabledPhaseCount() {
        XCTAssertEqual(TestSuiteConfig.default.enabledPhaseCount, 6)
    }

    // MARK: - Quick preset

    func testQuickPreset() {
        let quick = TestSuiteConfig.quick
        XCTAssertTrue(quick.runLatencyBurst)
        XCTAssertTrue(quick.runThroughput)
        XCTAssertTrue(quick.runJitter)
        XCTAssertTrue(quick.runPacketLoss)
        XCTAssertFalse(quick.runLatencyUnderLoad)
        XCTAssertFalse(quick.runHeavyLoad)
        XCTAssertEqual(quick.enabledPhaseCount, 4)
    }

    func testQuickPresetReducedParams() {
        let quick = TestSuiteConfig.quick
        let full = TestSuiteConfig.default
        XCTAssertLessThan(quick.latencyBurstCount, full.latencyBurstCount)
        XCTAssertLessThan(quick.throughputBytes, full.throughputBytes)
        XCTAssertLessThan(quick.jitterSampleCount, full.jitterSampleCount)
        XCTAssertLessThan(quick.packetLossCount, full.packetLossCount)
    }

    // MARK: - Enabled phase count

    func testEnabledPhaseCountCustom() {
        var config = TestSuiteConfig()
        config.runLatencyBurst = false
        config.runThroughput = false
        XCTAssertEqual(config.enabledPhaseCount, 4)

        config.runJitter = false
        config.runPacketLoss = false
        config.runLatencyUnderLoad = false
        config.runHeavyLoad = false
        XCTAssertEqual(config.enabledPhaseCount, 0)
    }

    // MARK: - Codable

    func testConfigRoundTrip() throws {
        var config = TestSuiteConfig()
        config.runHeavyLoad = false
        config.latencyBurstCount = 50
        config.bridgeTransports = ["native", "cordova", "flutter"]

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(TestSuiteConfig.self, from: data)

        XCTAssertFalse(decoded.runHeavyLoad)
        XCTAssertEqual(decoded.latencyBurstCount, 50)
        XCTAssertEqual(decoded.bridgeTransports, ["native", "cordova", "flutter"])
    }
}
