import Foundation

struct TestSuiteConfig: Codable {
    var latencyBurstCount: Int = 100
    var latencyBurstIntervalMs: Int = 50
    var throughputBytes: Int = 10_000_000
    var jitterSampleCount: Int = 150
    var jitterIntervalMs: Int = 80
    var packetLossCount: Int = 500
    var packetLossIntervalMs: Int = 10
    var runLatencyUnderLoad: Bool = true
    var runHeavyLoad: Bool = true

    static let `default` = TestSuiteConfig()

    static let quick = TestSuiteConfig(
        latencyBurstCount: 30,
        latencyBurstIntervalMs: 80,
        throughputBytes: 2_000_000,
        jitterSampleCount: 50,
        jitterIntervalMs: 100,
        packetLossCount: 100,
        packetLossIntervalMs: 25,
        runLatencyUnderLoad: false,
        runHeavyLoad: false
    )
}
