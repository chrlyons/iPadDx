import Foundation

struct TestReport: Codable, Identifiable {
    let id: UUID
    let date: Date
    let localDevice: DeviceInfo
    let remoteDevice: DeviceInfo
    let results: TestSuiteResults
    let durationSeconds: TimeInterval
}

struct DeviceInfo: Codable {
    let name: String
    let model: String
    let osVersion: String

    var chipFamily: String {
        let chips = ["M4", "M3", "M2", "M1", "A17", "A16", "A15", "A14", "A13", "A12"]
        for chip in chips {
            if model.contains(chip) { return chip }
        }
        // Fallback mapping for models without chip in the name
        let chipLookup: [String: String] = [
            "iPad mini (6th gen)": "A15",
            "iPad (10th gen)": "A14",
            "iPad Air (4th gen)": "A14",
            "iPad Air (5th gen)": "M1",
        ]
        return chipLookup[model] ?? "Unknown"
    }

    var shortDescription: String {
        "\(name) (\(chipFamily))"
    }

    var pairDescription: String {
        chipFamily
    }
}

struct TestSuiteResults: Codable {
    let latencyBurst: LatencyBurstResult
    let sustainedThroughput: ThroughputResult
    let jitterMeasurement: JitterResult
    let packetLossStress: PacketLossResult
    let latencyUnderLoad: LatencyUnderLoadResult
    let systemMetrics: SystemMetricsResult
    let overallGrade: String
}

struct LatencyUnderLoadResult: Codable {
    let baselineAvg: Double
    let underLoadAvg: Double
    let degradationPercent: Double
    let sampleCount: Int
}

struct SystemMetricsResult: Codable {
    let batteryStart: Float
    let batteryEnd: Float
    let batteryDrainPercent: Double
    let peakCpuUsage: Double
    let avgCpuUsage: Double
    let peakMemoryMB: Double
    let thermalStateDuringTest: String
}

struct LatencyBurstResult: Codable {
    let min: Double
    let max: Double
    let avg: Double
    let median: Double
    let p95: Double
    let sampleCount: Int
    let samples: [Double]
}

struct ThroughputResult: Codable {
    let bytesPerSecond: Double
    let totalBytes: Int
    let durationSeconds: Double

    var formattedSpeed: String {
        if bytesPerSecond >= 1_000_000 {
            return String(format: "%.1f MB/s", bytesPerSecond / 1_000_000)
        } else if bytesPerSecond >= 1000 {
            return String(format: "%.1f KB/s", bytesPerSecond / 1000)
        }
        return String(format: "%.0f B/s", bytesPerSecond)
    }
}

struct JitterResult: Codable {
    let averageJitter: Double
    let maxJitter: Double
    let sampleCount: Int
}

struct PacketLossResult: Codable {
    let sent: Int
    let received: Int
    let lostPercent: Double
    let durationSeconds: Double
}

struct HeavyLoadResult: Codable {
    let avgLatency: Double
    let maxLatency: Double
    let throughputBps: Double
    let packetLoss: Double
    let sampleCount: Int

    var formattedThroughput: String {
        if throughputBps >= 1_000_000 { return String(format: "%.1f MB/s", throughputBps / 1_000_000) }
        if throughputBps >= 1000 { return String(format: "%.1f KB/s", throughputBps / 1000) }
        return String(format: "%.0f B/s", throughputBps)
    }
}
