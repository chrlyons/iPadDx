import Foundation

@MainActor
@Observable
class ReportStore {
    var reports: [TestReport] = []

    private var directory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("Reports", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    init() {
        loadAll()
    }

    func save(_ report: TestReport) {
        let url = directory.appendingPathComponent("\(report.id.uuidString).json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(report) {
            try? data.write(to: url)
        }
        reports.insert(report, at: 0)
    }

    func delete(_ report: TestReport) {
        let url = directory.appendingPathComponent("\(report.id.uuidString).json")
        try? FileManager.default.removeItem(at: url)
        reports.removeAll { $0.id == report.id }
    }

    func exportURL(for report: TestReport) -> URL? {
        let url = directory.appendingPathComponent("\(report.id.uuidString).json")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func exportCSV(for report: TestReport) -> URL? {
        let r = report.results
        let csv = """
        iPadConnection Test Report
        Date,\(ISO8601DateFormatter().string(from: report.date))
        Duration,\(String(format: "%.1f", report.durationSeconds))s
        Overall Grade,\(r.overallGrade)

        Local Device
        Name,\(report.localDevice.name)
        Model,\(report.localDevice.model)
        Chip,\(report.localDevice.chipFamily)
        OS,\(report.localDevice.osVersion)

        Remote Device
        Name,\(report.remoteDevice.name)
        Model,\(report.remoteDevice.model)
        Chip,\(report.remoteDevice.chipFamily)
        OS,\(report.remoteDevice.osVersion)

        Latency Burst (\(r.latencyBurst.sampleCount) samples)
        Min,\(String(format: "%.2f", r.latencyBurst.min))ms
        Max,\(String(format: "%.2f", r.latencyBurst.max))ms
        Avg,\(String(format: "%.2f", r.latencyBurst.avg))ms
        Median,\(String(format: "%.2f", r.latencyBurst.median))ms
        P95,\(String(format: "%.2f", r.latencyBurst.p95))ms

        Throughput
        Speed,\(r.sustainedThroughput.formattedSpeed)
        Bytes,\(r.sustainedThroughput.totalBytes)
        Duration,\(String(format: "%.2f", r.sustainedThroughput.durationSeconds))s

        Jitter (\(r.jitterMeasurement.sampleCount) samples)
        Average,\(String(format: "%.2f", r.jitterMeasurement.averageJitter))ms
        Max,\(String(format: "%.2f", r.jitterMeasurement.maxJitter))ms

        Packet Loss (\(r.packetLossStress.sent) sent)
        Received,\(r.packetLossStress.received)
        Lost,\(String(format: "%.1f", r.packetLossStress.lostPercent))%
        Duration,\(String(format: "%.2f", r.packetLossStress.durationSeconds))s

        Latency Under Load (\(r.latencyUnderLoad.sampleCount) samples)
        Baseline Avg,\(String(format: "%.2f", r.latencyUnderLoad.baselineAvg))ms
        Under Load Avg,\(String(format: "%.2f", r.latencyUnderLoad.underLoadAvg))ms
        Degradation,\(String(format: "%.1f", r.latencyUnderLoad.degradationPercent))%

        System Metrics
        Battery Start,\(r.systemMetrics.batteryStart >= 0 ? "\(Int(r.systemMetrics.batteryStart * 100))%" : "N/A")
        Battery End,\(r.systemMetrics.batteryEnd >= 0 ? "\(Int(r.systemMetrics.batteryEnd * 100))%" : "N/A")
        Battery Drain,\(String(format: "%.2f", r.systemMetrics.batteryDrainPercent))%
        Peak CPU,\(String(format: "%.1f", r.systemMetrics.peakCpuUsage))%
        Avg CPU,\(String(format: "%.1f", r.systemMetrics.avgCpuUsage))%
        Peak Memory,\(String(format: "%.0f", r.systemMetrics.peakMemoryMB))MB
        Thermal State,\(r.systemMetrics.thermalStateDuringTest)
        """

        let fileName = "iPadConnection_Report_\(report.localDevice.chipFamily)_vs_\(report.remoteDevice.chipFamily)_\(report.id.uuidString.prefix(8)).csv"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try? csv.write(to: tempURL, atomically: true, encoding: .utf8)
        return tempURL
    }

    func loadAll() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return }
        reports = files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> TestReport? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(TestReport.self, from: data)
            }
            .sorted { $0.date > $1.date }
    }
}
