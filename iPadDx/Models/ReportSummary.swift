import Foundation

/// Per-metric validity for a summary row.
///
/// Mirrors `TestSuiteResults`: a disabled or cancelled phase stores zeros, and zero is
/// indistinguishable from a real reading for latency, jitter, loss and throughput.
/// Aggregations must filter on these instead of averaging the raw columns.
extension ReportSummary {
    var hasLatency: Bool {
        latencySampleCount > 0
    }

    var hasJitter: Bool {
        jitterSampleCount > 0
    }

    var hasPacketLoss: Bool {
        packetLossSent > 0
    }

    var hasThroughput: Bool {
        throughputBps > 0
    }

    /// Mirrors `TestSuiteResults.hasLoadDegradation`: degradation is only meaningful
    /// when the phase collected samples AND had a real baseline to compare against.
    /// Derived from stored columns, so reports written before this check still resolve
    /// correctly rather than defaulting to "unmeasured".
    var hasLoadDegradation: Bool {
        loadSampleCount > 0 && loadBaselineAvg > 0
    }

    var measuredLatencyAvg: Double? {
        hasLatency ? latencyAvg : nil
    }

    var measuredLatencyP95: Double? {
        hasLatency ? latencyP95 : nil
    }

    var measuredJitter: Double? {
        hasJitter ? jitterAvg : nil
    }

    var measuredPacketLoss: Double? {
        hasPacketLoss ? packetLossPercent : nil
    }

    var measuredThroughput: Double? {
        hasThroughput ? throughputBps : nil
    }

    /// Mirrors `TestSuiteResults.isFailure` using the persisted flag, so the analytics
    /// UI classifies a report exactly as the PDF and CSV paths do.
    var isFailure: Bool {
        !measuredAnything
            || overallGrade == SignalQuality.poor.rawValue
            || overallGrade == SignalQuality.fair.rawValue
    }

    var measuredLoadDegradation: Double? {
        hasLoadDegradation ? loadDegradation : nil
    }
}

/// Lightweight summary of a test report for list/analytics views.
/// Full `TestReport` is loaded on demand only when detail/export is needed.
struct ReportSummary: Identifiable {
    let id: UUID
    let date: Date
    let durationSeconds: Double
    let overallGrade: String
    let source: String

    // Device info (both sides)
    let localName: String
    let localModel: String
    let localModelNumber: String
    let localOS: String
    let localChip: String
    let remoteName: String
    let remoteModel: String
    let remoteModelNumber: String
    let remoteOS: String
    let remoteChip: String

    // Key metrics (for analytics aggregation)
    let latencyMin: Double
    let latencyMax: Double
    let latencyAvg: Double
    let latencyMedian: Double
    let latencyP95: Double
    let latencySampleCount: Int
    let throughputBps: Double
    let throughputBytes: Int
    let throughputDuration: Double
    let jitterAvg: Double
    let jitterMax: Double
    let jitterSampleCount: Int
    let packetLossSent: Int
    let packetLossReceived: Int
    let packetLossPercent: Double
    let packetLossDuration: Double
    let loadBaselineAvg: Double
    let loadUnderLoadAvg: Double
    let loadDegradation: Double
    let loadSampleCount: Int

    /// Bridge transport
    let bridgeTransport: String
    /// Whether the run used an Apple peer-to-peer (AWDL) link rather than an access
    /// point. Kept on the summary so analytics can split peer-to-peer from
    /// infrastructure without loading every full report.
    let usedPeerToPeer: Bool
    /// Times the link changed mid-run. Non-zero means the measurement is suspect.
    let linkChanges: Int
    /// Connection drops during the run.
    let linkDisconnects: Int
    /// Bonjour discovery dropouts during the run.
    let discoveryFlaps: Int
    /// See `ReportEntity.measuredAnything`.
    let measuredAnything: Bool

    /// Computed helpers matching DeviceInfo API
    var localChipFamily: String {
        localChip
    }

    var remoteChipFamily: String {
        remoteChip
    }

    var localDisplayModel: String {
        if localModel.isEmpty || localModel == "Unknown" {
            return localModelNumber
        }
        return localModel
    }

    var remoteDisplayModel: String {
        if remoteModel.isEmpty || remoteModel == "Unknown" {
            return remoteModelNumber
        }
        return remoteModel
    }

    var pairLabel: String {
        "\(localChip) vs \(remoteChip)"
    }
}

extension ReportSummary {
    init(from entity: ReportEntity) {
        id = entity.reportID
        date = entity.date
        durationSeconds = entity.durationSeconds
        overallGrade = entity.overallGrade
        source = entity.source

        localName = entity.localName
        localModel = entity.localModel
        localModelNumber = entity.localModelNumber ?? ""
        localOS = entity.localOS
        localChip = entity.localChip
        remoteName = entity.remoteName
        remoteModel = entity.remoteModel
        remoteModelNumber = entity.remoteModelNumber ?? ""
        remoteOS = entity.remoteOS
        remoteChip = entity.remoteChip

        latencyMin = entity.latencyMin
        latencyMax = entity.latencyMax
        latencyAvg = entity.latencyAvg
        latencyMedian = entity.latencyMedian
        latencyP95 = entity.latencyP95
        latencySampleCount = entity.latencySampleCount
        throughputBps = entity.throughputBps
        throughputBytes = entity.throughputBytes
        throughputDuration = entity.throughputDuration
        jitterAvg = entity.jitterAvg
        jitterMax = entity.jitterMax
        jitterSampleCount = entity.jitterSampleCount
        packetLossSent = entity.packetLossSent
        packetLossReceived = entity.packetLossReceived
        packetLossPercent = entity.packetLossPercent
        packetLossDuration = entity.packetLossDuration
        loadBaselineAvg = entity.loadBaselineAvg
        loadUnderLoadAvg = entity.loadUnderLoadAvg
        loadDegradation = entity.loadDegradation
        loadSampleCount = entity.loadSampleCount

        bridgeTransport = entity.bridgeTransport
        usedPeerToPeer = entity.usedPeerToPeer
        linkChanges = entity.linkChanges
        linkDisconnects = entity.linkDisconnects
        discoveryFlaps = entity.discoveryFlaps
        measuredAnything = entity.measuredAnything
    }

    init(from report: TestReport, source: String = "local") {
        id = report.id
        date = report.date
        durationSeconds = report.durationSeconds
        overallGrade = report.results.overallGrade
        self.source = source

        localName = report.localDevice.name
        localModel = report.localDevice.model
        localModelNumber = report.localDevice.modelNumber
        localOS = report.localDevice.osVersion
        localChip = report.localDevice.chipFamily
        remoteName = report.remoteDevice.name
        remoteModel = report.remoteDevice.model
        remoteModelNumber = report.remoteDevice.modelNumber
        remoteOS = report.remoteDevice.osVersion
        remoteChip = report.remoteDevice.chipFamily

        let l = report.results.latencyBurst
        latencyMin = l.min
        latencyMax = l.max
        latencyAvg = l.avg
        latencyMedian = l.median
        latencyP95 = l.p95
        latencySampleCount = l.sampleCount

        let t = report.results.sustainedThroughput
        throughputBps = t.bytesPerSecond
        throughputBytes = t.totalBytes
        throughputDuration = t.durationSeconds

        let j = report.results.jitterMeasurement
        jitterAvg = j.averageJitter
        jitterMax = j.maxJitter
        jitterSampleCount = j.sampleCount

        let p = report.results.packetLossStress
        packetLossSent = p.sent
        packetLossReceived = p.received
        packetLossPercent = p.lostPercent
        packetLossDuration = p.durationSeconds

        let u = report.results.latencyUnderLoad
        loadBaselineAvg = u.baselineAvg
        loadUnderLoadAvg = u.underLoadAvg
        loadDegradation = u.degradationPercent
        loadSampleCount = u.sampleCount

        bridgeTransport = report.bridgeTransport ?? "native"
        usedPeerToPeer = report.results.linkConditions?.usedPeerToPeer ?? false
        linkChanges = report.results.linkConditions?.pathChanges ?? 0
        linkDisconnects = report.results.linkConditions?.disconnects.count ?? 0
        discoveryFlaps = report.results.linkConditions?.discoveryFlaps ?? 0
        measuredAnything = !report.results.measuredNothing
    }
}

/// Comparison metrics across bridges for the same device pair.
/// One bridge's measured figures for a device pair.
///
/// Every metric is optional. Collapsing "no report measured this" to 0 made the bridge
/// screen state "Average round-trip latency measured…" above a 0.00 ms row — i.e. the
/// best possible result, presented as a measurement. nil means not measured.
struct BridgeComparisonRow: Identifiable {
    let bridge: String
    let reportCount: Int
    /// Reports that actually measured latency — this is what avgLatency averages,
    /// and it may be smaller than reportCount.
    let measuredLatencyCount: Int
    let avgLatency: Double?
    let avgJitter: Double?
    let avgPacketLoss: Double?
    let avgThroughput: Double?
    /// nil when no run in this group was graded.
    let avgGradeScore: Double?

    var id: String {
        bridge
    }

    /// Convert grade string to numeric score (0-12).
    /// Numeric score for a grade band, or nil when the run was not graded.
    ///
    /// This used to return 0 by default, which ranked an ungraded run BELOW Poor (3).
    /// A bridge whose runs were throughput-only — honestly ungraded — therefore
    /// averaged worse than a bridge actually measured as Poor, inverting the bridge
    /// comparison the tool exists for. Callers must average only the non-nil scores.
    static func gradeScore(_ grade: String) -> Double? {
        guard let quality = SignalQuality(rawValue: grade) else { return nil }
        switch quality {
        case .excellent: return 12
        case .good: return 9
        case .fair: return 6
        case .poor: return 3
        }
    }
}
