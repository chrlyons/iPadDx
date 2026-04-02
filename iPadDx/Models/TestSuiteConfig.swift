import Foundation

struct TestSuiteConfig: Codable {
    // Phase enable/disable
    var runLatencyBurst: Bool = true
    var runThroughput: Bool = true
    var runJitter: Bool = true
    var runPacketLoss: Bool = true
    var runLatencyUnderLoad: Bool = true
    var runHeavyLoad: Bool = true

    // Warm-up
    var runWarmUp: Bool = true
    var warmUpPingCount: Int = 10
    var warmUpIntervalMs: Int = 100

    // Phase parameters
    var latencyBurstCount: Int = 100
    var latencyBurstIntervalMs: Int = 50
    var throughputBytes: Int = 10_000_000
    var jitterSampleCount: Int = 150
    var jitterIntervalMs: Int = 80
    var packetLossCount: Int = 500
    var packetLossIntervalMs: Int = 10

    /// Which bridge transports to test through.
    /// Empty array or ["native"] = current behavior (no bridge overhead).
    /// ["native", "cordova"] = run the suite twice: once native, once through Cordova bridge.
    var bridgeTransports: [String] = ["native"]

    var enabledPhaseCount: Int {
        [runLatencyBurst, runThroughput, runJitter, runPacketLoss, runLatencyUnderLoad, runHeavyLoad]
            .filter(\.self).count
    }

    static let `default` = TestSuiteConfig()

    static let quick = TestSuiteConfig(
        runLatencyUnderLoad: false,
        runHeavyLoad: false,
        runWarmUp: true,
        latencyBurstCount: 30,
        latencyBurstIntervalMs: 80,
        throughputBytes: 2_000_000,
        jitterSampleCount: 50,
        jitterIntervalMs: 100,
        packetLossCount: 100,
        packetLossIntervalMs: 25
    )
}
