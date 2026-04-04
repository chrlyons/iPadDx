import Foundation

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

    /// Computed helpers matching DeviceInfo API
    var localChipFamily: String {
        localChip
    }

    var remoteChipFamily: String {
        remoteChip
    }

    var localDisplayModel: String {
        if localModel.isEmpty || localModel == "Unknown" { return localModelNumber }
        return localModel
    }

    var remoteDisplayModel: String {
        if remoteModel.isEmpty || remoteModel == "Unknown" { return remoteModelNumber }
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
    }
}

/// Comparison metrics across bridges for the same device pair.
struct BridgeComparisonRow: Identifiable {
    let bridge: String
    let reportCount: Int
    let avgLatency: Double
    let avgJitter: Double
    let avgPacketLoss: Double
    let avgThroughput: Double
    let avgGradeScore: Double

    var id: String {
        bridge
    }

    /// Convert grade string to numeric score (0-12).
    static func gradeScore(_ grade: String) -> Double {
        switch grade {
        case "Excellent": 12
        case "Good": 9
        case "Fair": 6
        case "Poor": 3
        default: 0
        }
    }
}
