import XCTest
@testable import iPadDx

final class DiagnosticMetricsTests: XCTestCase {

    // MARK: - Signal Quality

    @MainActor
    func testSignalQualityExcellent() {
        let metrics = DiagnosticMetrics()
        // Low latency, low variance
        for i in 0..<30 {
            metrics.appendLatency(Double.random(in: 3...7), maxHistory: 120)
        }
        XCTAssertEqual(metrics.signalQuality, .excellent)
    }

    @MainActor
    func testSignalQualityPoorWithFewSamples() {
        let metrics = DiagnosticMetrics()
        // Fewer than 5 samples always returns .poor
        metrics.appendLatency(3.0)
        metrics.appendLatency(4.0)
        XCTAssertEqual(metrics.signalQuality, .poor)
    }

    @MainActor
    func testSignalQualityPoorWithHighLatency() {
        let metrics = DiagnosticMetrics()
        for _ in 0..<30 {
            metrics.appendLatency(Double.random(in: 150...500), maxHistory: 120)
        }
        XCTAssertEqual(metrics.signalQuality, .poor)
    }

    // MARK: - Packet Loss

    @MainActor
    func testPacketLossPercentZeroWhenNoneResolved() {
        let metrics = DiagnosticMetrics()
        XCTAssertEqual(metrics.packetLossPercent, 0)
    }

    @MainActor
    func testPacketLossPercent() {
        let metrics = DiagnosticMetrics()
        metrics.pongsReceived = 90
        metrics.pingsLost = 10
        XCTAssertEqual(metrics.packetLossPercent, 10.0, accuracy: 0.01)
    }

    @MainActor
    func testPacketLossPercentAllReceived() {
        let metrics = DiagnosticMetrics()
        metrics.pongsReceived = 100
        metrics.pingsLost = 0
        XCTAssertEqual(metrics.packetLossPercent, 0)
    }

    // MARK: - Jitter

    @MainActor
    func testJitterWithSingleSample() {
        let metrics = DiagnosticMetrics()
        metrics.appendLatency(5.0)
        XCTAssertEqual(metrics.jitterMs, 0, "Jitter needs at least 2 samples")
    }

    @MainActor
    func testJitterCalculation() {
        let metrics = DiagnosticMetrics()
        // Add samples with known differences
        metrics.appendLatency(10.0)
        metrics.appendLatency(15.0) // diff = 5
        metrics.appendLatency(12.0) // diff = 3
        metrics.appendLatency(18.0) // diff = 6
        // Average jitter = (5 + 3 + 6) / 3 = 4.67
        XCTAssertEqual(metrics.jitterMs, 14.0 / 3.0, accuracy: 0.01)
    }

    // MARK: - Latency stats

    @MainActor
    func testLatencyMinMaxAvg() {
        let metrics = DiagnosticMetrics()
        metrics.appendLatency(10.0)
        metrics.appendLatency(20.0)
        metrics.appendLatency(30.0)
        XCTAssertEqual(metrics.latencyMin, 10.0)
        XCTAssertEqual(metrics.latencyMax, 30.0)
        XCTAssertEqual(metrics.latencyAvg, 20.0, accuracy: 0.01)
    }

    @MainActor
    func testLatencyStatsEmpty() {
        let metrics = DiagnosticMetrics()
        XCTAssertEqual(metrics.latencyMin, 0)
        XCTAssertEqual(metrics.latencyMax, 0)
        XCTAssertEqual(metrics.latencyAvg, 0)
    }

    // MARK: - Append latency trimming

    @MainActor
    func testAppendLatencyTrimsToMaxHistory() {
        let metrics = DiagnosticMetrics()
        for i in 0..<200 {
            metrics.appendLatency(Double(i))
        }
        XCTAssertEqual(metrics.latencyHistory.count, 120, "Should trim to maxHistory")
    }

    @MainActor
    func testAppendLatencyCustomMaxHistory() {
        let metrics = DiagnosticMetrics()
        for i in 0..<50 {
            metrics.appendLatency(Double(i), maxHistory: 10)
        }
        XCTAssertEqual(metrics.latencyHistory.count, 10)
    }

    // MARK: - Log events

    @MainActor
    func testLogEventTrimsToMax() {
        let metrics = DiagnosticMetrics()
        for i in 0..<60 {
            metrics.logEvent("Event \(i)")
        }
        XCTAssertEqual(metrics.connectionLog.count, 50, "Should trim to 50 events")
        // Most recent should be first
        XCTAssertEqual(metrics.connectionLog.first?.event, "Event 59")
    }

    // MARK: - Formatting

    @MainActor
    func testFormattedThroughput() {
        let metrics = DiagnosticMetrics()

        metrics.throughputBytesPerSec = nil
        XCTAssertEqual(metrics.formattedThroughput, "Not tested")

        metrics.throughputBytesPerSec = 5_000_000
        XCTAssertEqual(metrics.formattedThroughput, "5.0 MB/s")

        metrics.throughputBytesPerSec = 50_000
        XCTAssertEqual(metrics.formattedThroughput, "50.0 KB/s")

        metrics.throughputBytesPerSec = 500
        XCTAssertEqual(metrics.formattedThroughput, "500 B/s")
    }

    @MainActor
    func testFormattedBytes() {
        let metrics = DiagnosticMetrics()

        metrics.bytesSent = 5_000_000
        XCTAssertEqual(metrics.formattedBytesSent, "5.0 MB")

        metrics.bytesSent = 50_000
        XCTAssertEqual(metrics.formattedBytesSent, "50.0 KB")

        metrics.bytesSent = 500
        XCTAssertEqual(metrics.formattedBytesSent, "500 B")
    }

    @MainActor
    func testBatteryPercent() {
        let metrics = DiagnosticMetrics()

        metrics.batteryLevel = -1
        XCTAssertEqual(metrics.batteryPercent, "N/A")

        metrics.batteryLevel = 0.85
        XCTAssertEqual(metrics.batteryPercent, "85%")
    }
}
