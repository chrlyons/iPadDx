import Foundation

struct TestReport: Codable, Identifiable {
    let id: UUID
    let date: Date
    let localDevice: DeviceInfo
    let remoteDevice: DeviceInfo
    let results: TestSuiteResults
    let durationSeconds: TimeInterval
    let errors: [String]?
    let skippedPhases: [String]?

    /// The bridge transport used for this test run.
    /// "native" for direct Network.framework, "cordova" for Cordova bridge, etc.
    /// nil for backward compatibility with reports created before this feature.
    let bridgeTransport: String?

    /// Support decoding reports that don't have errors/skippedPhases/bridgeTransport yet
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        date = try container.decode(Date.self, forKey: .date)
        localDevice = try container.decode(DeviceInfo.self, forKey: .localDevice)
        remoteDevice = try container.decode(DeviceInfo.self, forKey: .remoteDevice)
        results = try container.decode(TestSuiteResults.self, forKey: .results)
        durationSeconds = try container.decode(TimeInterval.self, forKey: .durationSeconds)
        errors = try container.decodeIfPresent([String].self, forKey: .errors)
        skippedPhases = try container.decodeIfPresent([String].self, forKey: .skippedPhases)
        bridgeTransport = try container.decodeIfPresent(String.self, forKey: .bridgeTransport)
    }

    init(
        id: UUID,
        date: Date,
        localDevice: DeviceInfo,
        remoteDevice: DeviceInfo,
        results: TestSuiteResults,
        durationSeconds: TimeInterval,
        errors: [String]? = nil,
        skippedPhases: [String]? = nil,
        bridgeTransport: String? = nil
    ) {
        self.id = id
        self.date = date
        self.localDevice = localDevice
        self.remoteDevice = remoteDevice
        self.results = results
        self.durationSeconds = durationSeconds
        self.errors = errors
        self.skippedPhases = skippedPhases
        self.bridgeTransport = bridgeTransport
    }
}

struct DeviceInfo: Codable, Equatable {
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
        if model.isEmpty || model == "Unknown" {
            return modelNumber
        }
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
            if modelName.contains(chip) {
                return chip
            }
        }
        // Try looking up by hardware identifier
        if let entry = catalog[modelNumber] {
            return entry.chip
        }
        // Try looking up by model name (in case modelName IS the identifier)
        if let entry = catalog[modelName] {
            return entry.chip
        }
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
    let responderMetrics: ResponderMetricsResult?
    let dnsResolution: DNSResolutionResult?
    /// Phase 6 results. Previously computed and then discarded because there was
    /// nowhere to put them.
    let heavyLoad: HeavyLoadResult?
    /// The network path the test actually ran over.
    let linkConditions: LinkConditions?

    init(
        latencyBurst: LatencyBurstResult,
        sustainedThroughput: ThroughputResult,
        jitterMeasurement: JitterResult,
        packetLossStress: PacketLossResult,
        latencyUnderLoad: LatencyUnderLoadResult,
        systemMetrics: SystemMetricsResult,
        overallGrade: String,
        responderMetrics: ResponderMetricsResult? = nil,
        dnsResolution: DNSResolutionResult? = nil,
        heavyLoad: HeavyLoadResult? = nil,
        linkConditions: LinkConditions? = nil
    ) {
        self.latencyBurst = latencyBurst
        self.sustainedThroughput = sustainedThroughput
        self.jitterMeasurement = jitterMeasurement
        self.packetLossStress = packetLossStress
        self.latencyUnderLoad = latencyUnderLoad
        self.systemMetrics = systemMetrics
        self.overallGrade = overallGrade
        self.responderMetrics = responderMetrics
        self.dnsResolution = dnsResolution
        self.heavyLoad = heavyLoad
        self.linkConditions = linkConditions
    }

    /// Support decoding reports written before responderMetrics, dnsResolution or heavyLoad existed
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        latencyBurst = try container.decode(LatencyBurstResult.self, forKey: .latencyBurst)
        sustainedThroughput = try container.decode(ThroughputResult.self, forKey: .sustainedThroughput)
        jitterMeasurement = try container.decode(JitterResult.self, forKey: .jitterMeasurement)
        packetLossStress = try container.decode(PacketLossResult.self, forKey: .packetLossStress)
        latencyUnderLoad = try container.decode(LatencyUnderLoadResult.self, forKey: .latencyUnderLoad)
        systemMetrics = try container.decode(SystemMetricsResult.self, forKey: .systemMetrics)
        overallGrade = try container.decode(String.self, forKey: .overallGrade)
        responderMetrics = try container.decodeIfPresent(ResponderMetricsResult.self, forKey: .responderMetrics)
        dnsResolution = try container.decodeIfPresent(DNSResolutionResult.self, forKey: .dnsResolution)
        heavyLoad = try container.decodeIfPresent(HeavyLoadResult.self, forKey: .heavyLoad)
        linkConditions = try container.decodeIfPresent(LinkConditions.self, forKey: .linkConditions)
    }
}

struct ResponderMetricsResult: Codable {
    let peakCpuUsage: Double
    let avgCpuUsage: Double
    let peakMemoryMB: Double
    let thermalStateDuringTest: String
    let batteryDrainPercent: Double
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

struct ThermalTransitionRecord: Codable, Identifiable {
    var id: Date {
        timestamp
    }

    let timestamp: Date
    let from: String
    let to: String
}

/// What the network path actually looked like while the test ran.
///
/// The distinction that matters for peer-to-peer work is AWDL versus infrastructure
/// Wi-Fi. `NWInterface.type` reports `.wifi` for BOTH, so the only reliable signal is
/// the interface NAME: Apple's peer-to-peer links appear as `awdl0`. Without this a
/// stored report cannot say whether it measured a direct device-to-device link or a
/// round trip through an access point.
struct LinkConditions: Codable {
    /// e.g. "en0", "awdl0"
    let interfaceName: String?
    /// e.g. "Wi-Fi", "Ethernet"
    let interfaceType: String
    /// True when the path ran over an Apple peer-to-peer link (AWDL).
    let usedPeerToPeer: Bool
    let pathStatus: String
    let isExpensive: Bool
    let isConstrained: Bool
    let ssid: String?
    let bssid: String?
    /// How many times the interface set changed during the test. Anything above 0
    /// means the link moved underneath the measurement.
    let pathChanges: Int
    /// Connection drops recorded during the test window.
    let disconnects: [LinkDisconnect]
    /// Times the peer vanished from Bonjour browse results and returned during the run.
    /// Non-zero points at discovery/radio instability rather than a throughput problem.
    let discoveryFlaps: Int?

    /// Neither form involves the internet — this distinguishes a DIRECT radio link
    /// between the two devices from one that still hops through a local access point.
    var summary: String {
        let link = usedPeerToPeer
            ? "Direct device-to-device (AWDL)"
            : "Local network via access point"
        let iface = interfaceName.map { " · \($0)" } ?? ""
        return "\(link)\(iface)"
    }
}

struct LinkDisconnect: Codable {
    let timestamp: Date
    let reason: String
    let detail: String
}

struct DNSResolutionResult: Codable {
    let resolutionTimeMs: Double
    let resolved: Bool
    let serviceName: String
    /// Every service name visible during the browse. Recorded so a failure to find the
    /// expected name can be diagnosed after the fact rather than only reproduced.
    let discoveredNames: [String]?

    init(
        resolutionTimeMs: Double,
        resolved: Bool,
        serviceName: String,
        discoveredNames: [String]? = nil
    ) {
        self.resolutionTimeMs = resolutionTimeMs
        self.resolved = resolved
        self.serviceName = serviceName
        self.discoveredNames = discoveredNames
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        resolutionTimeMs = try c.decode(Double.self, forKey: .resolutionTimeMs)
        resolved = try c.decode(Bool.self, forKey: .resolved)
        serviceName = try c.decode(String.self, forKey: .serviceName)
        discoveredNames = try c.decodeIfPresent([String].self, forKey: .discoveredNames)
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
    let thermalTransitions: [ThermalTransitionRecord]?

    init(
        batteryStart: Float, batteryEnd: Float, batteryDrainPercent: Double,
        peakCpuUsage: Double, avgCpuUsage: Double, peakMemoryMB: Double,
        thermalStateDuringTest: String, thermalTransitions: [ThermalTransitionRecord]? = nil
    ) {
        self.batteryStart = batteryStart
        self.batteryEnd = batteryEnd
        self.batteryDrainPercent = batteryDrainPercent
        self.peakCpuUsage = peakCpuUsage
        self.avgCpuUsage = avgCpuUsage
        self.peakMemoryMB = peakMemoryMB
        self.thermalStateDuringTest = thermalStateDuringTest
        self.thermalTransitions = thermalTransitions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        batteryStart = try c.decode(Float.self, forKey: .batteryStart)
        batteryEnd = try c.decode(Float.self, forKey: .batteryEnd)
        batteryDrainPercent = try c.decode(Double.self, forKey: .batteryDrainPercent)
        peakCpuUsage = try c.decode(Double.self, forKey: .peakCpuUsage)
        avgCpuUsage = try c.decode(Double.self, forKey: .avgCpuUsage)
        peakMemoryMB = try c.decode(Double.self, forKey: .peakMemoryMB)
        thermalStateDuringTest = try c.decode(String.self, forKey: .thermalStateDuringTest)
        thermalTransitions = try c.decodeIfPresent([ThermalTransitionRecord].self, forKey: .thermalTransitions)
    }
}

struct HistogramBucket: Codable, Identifiable {
    var id: Double {
        rangeStart
    }

    let rangeStart: Double
    let rangeEnd: Double
    let count: Int
}

struct LatencyBurstResult: Codable {
    let min: Double
    let max: Double
    let avg: Double
    let median: Double
    let p95: Double
    let sampleCount: Int
    let samples: [Double]
    let p5: Double?
    let p25: Double?
    let p75: Double?
    let p99: Double?
    let histogram: [HistogramBucket]?
    let anomalyCount: Int?

    init(
        min: Double, max: Double, avg: Double, median: Double, p95: Double,
        sampleCount: Int, samples: [Double],
        p5: Double? = nil, p25: Double? = nil, p75: Double? = nil, p99: Double? = nil,
        histogram: [HistogramBucket]? = nil, anomalyCount: Int? = nil
    ) {
        self.min = min
        self.max = max
        self.avg = avg
        self.median = median
        self.p95 = p95
        self.sampleCount = sampleCount
        self.samples = samples
        self.p5 = p5
        self.p25 = p25
        self.p75 = p75
        self.p99 = p99
        self.histogram = histogram
        self.anomalyCount = anomalyCount
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        min = try c.decode(Double.self, forKey: .min)
        max = try c.decode(Double.self, forKey: .max)
        avg = try c.decode(Double.self, forKey: .avg)
        median = try c.decode(Double.self, forKey: .median)
        p95 = try c.decode(Double.self, forKey: .p95)
        sampleCount = try c.decode(Int.self, forKey: .sampleCount)
        samples = try c.decode([Double].self, forKey: .samples)
        p5 = try c.decodeIfPresent(Double.self, forKey: .p5)
        p25 = try c.decodeIfPresent(Double.self, forKey: .p25)
        p75 = try c.decodeIfPresent(Double.self, forKey: .p75)
        p99 = try c.decodeIfPresent(Double.self, forKey: .p99)
        histogram = try c.decodeIfPresent([HistogramBucket].self, forKey: .histogram)
        anomalyCount = try c.decodeIfPresent(Int.self, forKey: .anomalyCount)
    }

    static func buildHistogram(samples: [Double], bucketCount: Int = 20) -> [HistogramBucket] {
        let sorted = samples.sorted()
        guard let lo = sorted.first, let hi = sorted.last, hi > lo else { return [] }
        let width = (hi - lo) / Double(bucketCount)
        var buckets = (0 ..< bucketCount).map { i in
            HistogramBucket(rangeStart: lo + Double(i) * width, rangeEnd: lo + Double(i + 1) * width, count: 0)
        }
        for s in samples {
            let idx = Swift.min(Int((s - lo) / width), bucketCount - 1)
            buckets[idx] = HistogramBucket(
                rangeStart: buckets[idx].rangeStart,
                rangeEnd: buckets[idx].rangeEnd,
                count: buckets[idx].count + 1
            )
        }
        return buckets
    }

    /// Linear-interpolated percentile over an already-sorted sample array.
    ///
    /// The previous form indexed `Int(count * p)`, which returns the (n·p + 1)-th
    /// smallest value — for p95 over 100 samples that is the 96th, not the 95th.
    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        guard sorted.count > 1 else { return sorted[0] }
        let clamped = Swift.max(0, Swift.min(1, p))
        let position = clamped * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = Swift.min(lower + 1, sorted.count - 1)
        let fraction = position - Double(lower)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * fraction
    }

    /// True median: the mean of the two central values when the count is even.
    static func median(_ sorted: [Double]) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    /// Number of samples more than 3 standard deviations above the mean.
    /// Returns nil when there is too little data for the statistic to mean anything.
    static func anomalyCount(in samples: [Double]) -> Int? {
        guard samples.count >= 10 else { return nil }
        let mean = samples.reduce(0, +) / Double(samples.count)
        let variance = samples.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(samples.count)
        let stddev = variance.squareRoot()
        guard stddev > 0.5 else { return 0 }
        let threshold = mean + 3 * stddev
        return samples.filter { $0 > threshold }.count
    }
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
        if averageJitter < 5 {
            return "Stable"
        }
        if averageJitter < 15 {
            return "Moderate"
        }
        if averageJitter < 30 {
            return "Unstable"
        }
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
        if throughputBps >= 1_000_000 {
            return String(format: "%.1f MB/s", throughputBps / 1_000_000)
        }
        if throughputBps >= 1000 {
            return String(format: "%.1f KB/s", throughputBps / 1000)
        }
        return String(format: "%.0f B/s", throughputBps)
    }
}
