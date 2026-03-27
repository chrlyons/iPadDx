import Foundation

struct TestReport: Codable, Identifiable {
    let id: UUID
    let date: Date
    let localDevice: DeviceInfo
    let remoteDevice: DeviceInfo
    let results: TestSuiteResults
    let durationSeconds: TimeInterval
    let errors: [String]?

    /// Support decoding reports that don't have errors yet
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        date = try container.decode(Date.self, forKey: .date)
        localDevice = try container.decode(DeviceInfo.self, forKey: .localDevice)
        remoteDevice = try container.decode(DeviceInfo.self, forKey: .remoteDevice)
        results = try container.decode(TestSuiteResults.self, forKey: .results)
        durationSeconds = try container.decode(TimeInterval.self, forKey: .durationSeconds)
        errors = try container.decodeIfPresent([String].self, forKey: .errors)
    }

    init(
        id: UUID,
        date: Date,
        localDevice: DeviceInfo,
        remoteDevice: DeviceInfo,
        results: TestSuiteResults,
        durationSeconds: TimeInterval,
        errors: [String]? = nil
    ) {
        self.id = id
        self.date = date
        self.localDevice = localDevice
        self.remoteDevice = remoteDevice
        self.results = results
        self.durationSeconds = durationSeconds
        self.errors = errors
    }
}

struct DeviceInfo: Codable {
    let name: String
    let model: String // Pretty name: "iPad Pro 13-inch (M4)"
    let modelNumber: String // Hardware ID: "iPad16,3"
    let osVersion: String

    /// Support decoding reports that don't have modelNumber yet
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        model = try container.decode(String.self, forKey: .model)
        modelNumber = try container.decodeIfPresent(String.self, forKey: .modelNumber) ?? ""
        osVersion = try container.decode(String.self, forKey: .osVersion)
    }

    init(name: String, model: String, modelNumber: String = "", osVersion: String) {
        self.name = name
        self.model = model
        self.modelNumber = modelNumber
        self.osVersion = osVersion
    }

    var chipFamily: String {
        iPadCatalog.chipFamily(for: model, modelNumber: modelNumber)
    }

    var displayModel: String {
        if model.isEmpty || model == "Unknown" { return modelNumber }
        return model
    }

    var shortDescription: String {
        "\(name) (\(chipFamily))"
    }

    var pairDescription: String {
        chipFamily
    }
}

/// Consolidated iPad hardware catalog
enum iPadCatalog {
    struct Entry {
        let modelName: String
        let chip: String
    }

    static let catalog: [String: Entry] = [
        // iPad Air (4th gen) — A14
        "iPad13,1": Entry(modelName: "iPad Air (4th gen)", chip: "A14"),
        "iPad13,2": Entry(modelName: "iPad Air (4th gen)", chip: "A14"),
        // iPad Pro 11" (3rd gen) — M1
        "iPad13,4": Entry(modelName: "iPad Pro 11-inch (3rd gen)", chip: "M1"),
        "iPad13,5": Entry(modelName: "iPad Pro 11-inch (3rd gen)", chip: "M1"),
        "iPad13,6": Entry(modelName: "iPad Pro 11-inch (3rd gen)", chip: "M1"),
        "iPad13,7": Entry(modelName: "iPad Pro 11-inch (3rd gen)", chip: "M1"),
        // iPad Pro 12.9" (5th gen) — M1
        "iPad13,8": Entry(modelName: "iPad Pro 12.9-inch (5th gen)", chip: "M1"),
        "iPad13,9": Entry(modelName: "iPad Pro 12.9-inch (5th gen)", chip: "M1"),
        "iPad13,10": Entry(modelName: "iPad Pro 12.9-inch (5th gen)", chip: "M1"),
        "iPad13,11": Entry(modelName: "iPad Pro 12.9-inch (5th gen)", chip: "M1"),
        // iPad Air (5th gen) — M1
        "iPad13,16": Entry(modelName: "iPad Air (5th gen)", chip: "M1"),
        "iPad13,17": Entry(modelName: "iPad Air (5th gen)", chip: "M1"),
        // iPad (10th gen) — A14
        "iPad13,18": Entry(modelName: "iPad (10th gen)", chip: "A14"),
        "iPad13,19": Entry(modelName: "iPad (10th gen)", chip: "A14"),
        // iPad mini (6th gen) — A15
        "iPad14,1": Entry(modelName: "iPad mini (6th gen)", chip: "A15"),
        "iPad14,2": Entry(modelName: "iPad mini (6th gen)", chip: "A15"),
        // iPad Pro 11" (4th gen) — M2
        "iPad14,3": Entry(modelName: "iPad Pro 11-inch (4th gen)", chip: "M2"),
        "iPad14,4": Entry(modelName: "iPad Pro 11-inch (4th gen)", chip: "M2"),
        // iPad Pro 12.9" (6th gen) — M2
        "iPad14,5": Entry(modelName: "iPad Pro 12.9-inch (6th gen)", chip: "M2"),
        "iPad14,6": Entry(modelName: "iPad Pro 12.9-inch (6th gen)", chip: "M2"),
        // iPad Air 11" (M2)
        "iPad14,8": Entry(modelName: "iPad Air 11-inch (M2)", chip: "M2"),
        "iPad14,9": Entry(modelName: "iPad Air 11-inch (M2)", chip: "M2"),
        // iPad Air 13" (M2)
        "iPad14,10": Entry(modelName: "iPad Air 13-inch (M2)", chip: "M2"),
        "iPad14,11": Entry(modelName: "iPad Air 13-inch (M2)", chip: "M2"),
        // iPad Air 11" (M3) — 2025
        "iPad15,3": Entry(modelName: "iPad Air 11-inch (M3)", chip: "M3"),
        "iPad15,4": Entry(modelName: "iPad Air 11-inch (M3)", chip: "M3"),
        // iPad Air 13" (M3) — 2025
        "iPad15,5": Entry(modelName: "iPad Air 13-inch (M3)", chip: "M3"),
        "iPad15,6": Entry(modelName: "iPad Air 13-inch (M3)", chip: "M3"),
        // iPad (11th gen) — A16
        "iPad15,7": Entry(modelName: "iPad (11th gen)", chip: "A16"),
        "iPad15,8": Entry(modelName: "iPad (11th gen)", chip: "A16"),
        // iPad mini (7th gen) — A17 Pro
        "iPad16,1": Entry(modelName: "iPad mini (7th gen)", chip: "A17 Pro"),
        "iPad16,2": Entry(modelName: "iPad mini (7th gen)", chip: "A17 Pro"),
        // iPad Pro 11" (M4)
        "iPad16,3": Entry(modelName: "iPad Pro 11-inch (M4)", chip: "M4"),
        "iPad16,4": Entry(modelName: "iPad Pro 11-inch (M4)", chip: "M4"),
        // iPad Pro 13" (M4)
        "iPad16,5": Entry(modelName: "iPad Pro 13-inch (M4)", chip: "M4"),
        "iPad16,6": Entry(modelName: "iPad Pro 13-inch (M4)", chip: "M4"),
        // iPad Air 11" (M4) — 2026
        "iPad16,8": Entry(modelName: "iPad Air 11-inch (M4)", chip: "M4"),
        "iPad16,9": Entry(modelName: "iPad Air 11-inch (M4)", chip: "M4"),
        // iPad Air 13" (M4) — 2026
        "iPad16,10": Entry(modelName: "iPad Air 13-inch (M4)", chip: "M4"),
        "iPad16,11": Entry(modelName: "iPad Air 13-inch (M4)", chip: "M4"),
    ]

    static func modelName(for identifier: String) -> String {
        catalog[identifier]?.modelName ?? identifier
    }

    static func chipFamily(for modelName: String, modelNumber: String = "") -> String {
        // Check pretty model name for chip identifiers
        let chips = ["M4", "M3", "M2", "M1", "A17", "A16", "A15", "A14", "A13", "A12"]
        for chip in chips {
            if modelName.contains(chip) { return chip }
        }
        // Try looking up by hardware identifier
        if let entry = catalog[modelNumber] { return entry.chip }
        // Try looking up by model name (in case modelName IS the identifier)
        if let entry = catalog[modelName] { return entry.chip }
        return modelName.isEmpty || modelName == "Unknown" ? "Unknown" : modelName
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
    let degradationPercent: Double // negative = improvement under load
    let sampleCount: Int

    var formattedDegradation: String {
        if degradationPercent > 0 {
            return String(format: "+%.1f%% (worse)", degradationPercent)
        } else if degradationPercent < 0 {
            return String(format: "%.1f%% (improved)", degradationPercent)
        }
        return "0% (no change)"
    }
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

    var qualityLabel: String {
        if averageJitter < 5 { return "Stable" }
        if averageJitter < 15 { return "Moderate" }
        if averageJitter < 30 { return "Unstable" }
        return "Very Unstable"
    }
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
