import Foundation
import SwiftData

@Model
class ReportEntity {
    @Attribute(.unique) var reportID: UUID
    /// Link characteristics. Defaulted so stores written before these existed
    /// migrate without a schema break.
    var usedPeerToPeer: Bool = false
    var linkChanges: Int = 0
    var linkDisconnects: Int = 0
    var discoveryFlaps: Int = 0
    var date: Date
    var durationSeconds: Double
    var overallGrade: String
    var source: String // "local" or "remote"

    // Local device
    var localName: String
    var localModel: String
    var localModelNumber: String?
    var localOS: String
    var localChip: String

    // Remote device
    var remoteName: String
    var remoteModel: String
    var remoteModelNumber: String?
    var remoteOS: String
    var remoteChip: String

    // Latency burst
    var latencyMin: Double
    var latencyMax: Double
    var latencyAvg: Double
    var latencyMedian: Double
    var latencyP95: Double
    var latencySampleCount: Int

    // Throughput
    var throughputBps: Double
    var throughputBytes: Int
    var throughputDuration: Double

    // Jitter
    var jitterAvg: Double
    var jitterMax: Double
    var jitterSampleCount: Int

    // Packet loss
    var packetLossSent: Int
    var packetLossReceived: Int
    var packetLossPercent: Double
    var packetLossDuration: Double

    // Latency under load
    var loadBaselineAvg: Double
    var loadUnderLoadAvg: Double
    var loadDegradation: Double
    var loadSampleCount: Int

    // System
    var batteryStart: Float
    var batteryEnd: Float
    var batteryDrain: Double
    var peakCPU: Double
    var avgCPU: Double
    var peakMemory: Double
    var thermalState: String

    /// Bridge transport identifier. "native" | "cordova" | "reactnative" | etc.
    /// Defaults to "native" for migrated records.
    var bridgeTransport: String = "native"

    /// Raw JSON for full report export
    var rawJSON: Data?

    init(from report: TestReport, source: String = "local") {
        reportID = report.id
        date = report.date
        durationSeconds = report.durationSeconds
        overallGrade = report.results.overallGrade
        self.source = source
        bridgeTransport = report.bridgeTransport ?? "native"
        usedPeerToPeer = report.results.linkConditions?.usedPeerToPeer ?? false
        linkChanges = report.results.linkConditions?.pathChanges ?? 0
        linkDisconnects = report.results.linkConditions?.disconnects.count ?? 0
        discoveryFlaps = report.results.linkConditions?.discoveryFlaps ?? 0

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

        let s = report.results.systemMetrics
        batteryStart = s.batteryStart
        batteryEnd = s.batteryEnd
        batteryDrain = s.batteryDrainPercent
        peakCPU = s.peakCpuUsage
        avgCPU = s.avgCpuUsage
        peakMemory = s.peakMemoryMB
        thermalState = s.thermalStateDuringTest

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        rawJSON = try? encoder.encode(report)
    }

    var devicePair: String {
        "\(localChip) vs \(remoteChip)"
    }

    func toTestReport() -> TestReport? {
        guard let data = rawJSON else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(TestReport.self, from: data)
    }

    func toSummary() -> ReportSummary {
        ReportSummary(from: self)
    }
}
