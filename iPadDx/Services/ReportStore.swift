import Foundation
import SwiftData

@MainActor
@Observable
class ReportStore {
    var reports: [TestReport] = []

    private var modelContainer: ModelContainer?
    private var modelContext: ModelContext?

    init() {
        do {
            let schema = Schema([ReportEntity.self])
            let config = ModelConfiguration("iPadDxReports", isStoredInMemoryOnly: false)
            // Allow lightweight migration so schema changes don't wipe data
            modelContainer = try ModelContainer(
                for: schema,
                migrationPlan: nil,
                configurations: [config]
            )
            modelContext = modelContainer.map { ModelContext($0) }
        } catch {
            print("SwiftData init failed: \(error), attempting fresh database")
            // If migration fails, try fresh (this only happens on major schema changes)
            do {
                let config = ModelConfiguration("iPadDxReports", isStoredInMemoryOnly: false)
                modelContainer = try ModelContainer(for: ReportEntity.self, configurations: config)
                modelContext = modelContainer.map { ModelContext($0) }
            } catch {
                print("SwiftData fallback also failed: \(error)")
            }
        }
        loadAll()
    }

    func save(_ report: TestReport, source: String = "local") {
        // Save to SwiftData
        if let context = modelContext {
            let entity = ReportEntity(from: report, source: source)
            context.insert(entity)
            try? context.save()
        }

        // Keep in-memory list updated
        if !reports.contains(where: { $0.id == report.id }) {
            reports.insert(report, at: 0)
        }
    }

    func delete(_ report: TestReport) {
        if let context = modelContext {
            let reportID = report.id
            let predicate = #Predicate<ReportEntity> { $0.reportID == reportID }
            let descriptor = FetchDescriptor<ReportEntity>(predicate: predicate)
            if let entities = try? context.fetch(descriptor) {
                for entity in entities {
                    context.delete(entity)
                }
                try? context.save()
            }
        }
        reports.removeAll { $0.id == report.id }
    }

    func loadAll() {
        guard let context = modelContext else { return }
        let descriptor = FetchDescriptor<ReportEntity>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        guard let entities = try? context.fetch(descriptor) else { return }
        reports = entities.compactMap { $0.toTestReport() }
    }

    // MARK: - Queries

    func reports(forChipPair local: String, remote: String) -> [TestReport] {
        reports.filter { $0.localDevice.chipFamily == local && $0.remoteDevice.chipFamily == remote }
    }

    func reports(fromSource source: String) -> [TestReport] {
        guard let context = modelContext else { return [] }
        let predicate = #Predicate<ReportEntity> { $0.source == source }
        let descriptor = FetchDescriptor<ReportEntity>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        guard let entities = try? context.fetch(descriptor) else { return [] }
        return entities.compactMap { $0.toTestReport() }
    }

    func averageLatency(forChip chip: String) -> Double? {
        guard let context = modelContext else { return nil }
        let descriptor = FetchDescriptor<ReportEntity>()
        guard let entities = try? context.fetch(descriptor) else { return nil }
        let matching = entities.filter { $0.localChip == chip || $0.remoteChip == chip }
        guard !matching.isEmpty else { return nil }
        return matching.map(\.latencyAvg).reduce(0, +) / Double(matching.count)
    }

    // MARK: - Sync

    func encodeForSync(_ report: TestReport) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(report)
    }

    func decodeFromSync(_ data: Data) -> TestReport? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(TestReport.self, from: data)
    }

    func importRemoteReport(_ report: TestReport) {
        guard !reports.contains(where: { $0.id == report.id }) else { return }
        save(report, source: "remote")
    }

    // MARK: - Export

    func exportCSV(for report: TestReport) -> URL? {
        let r = report.results
        let csv = """
        iPadDx Test Report
        Date,\(ISO8601DateFormatter().string(from: report.date))
        Duration,\(String(format: "%.1f", report.durationSeconds))s
        Overall Grade,\(r.overallGrade)

        Local Device
        Name,\(report.localDevice.name)
        Model,\(report.localDevice.displayModel)
        Model #,"\(report.localDevice.modelNumber)"
        Chip,\(report.localDevice.chipFamily)
        OS,\(report.localDevice.osVersion)

        Remote Device
        Name,\(report.remoteDevice.name)
        Model,\(report.remoteDevice.displayModel)
        Model #,"\(report.remoteDevice.modelNumber)"
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

        let fileName = "iPadDx_Report_\(report.localDevice.chipFamily)_vs_\(report.remoteDevice.chipFamily)_\(report.id.uuidString.prefix(8)).csv"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try? csv.write(to: tempURL, atomically: true, encoding: .utf8)
        return tempURL
    }

    // swiftlint:disable function_body_length
    func exportSummaryCSV(for reports: [TestReport]) -> URL? {
        let headers = [
            // Device info
            "Date",
            "Local Name",
            "Local Model",
            "Local Model #",
            "Local Chip",
            "Local OS",
            "Remote Name",
            "Remote Model",
            "Remote Model #",
            "Remote Chip",
            "Remote OS",
            // Overall
            "Grade",
            "Duration (s)",
            // Latency
            "Latency Min (ms)",
            "Latency Max (ms)",
            "Latency Avg (ms)",
            "Latency Median (ms)",
            "Latency P95 (ms)",
            "Latency Samples",
            // Throughput
            "Throughput (MB/s)",
            "Throughput Bytes",
            "Throughput Duration (s)",
            // Jitter
            "Jitter Avg (ms)",
            "Jitter Max (ms)",
            "Jitter Samples",
            // Packet Loss
            "PL Sent",
            "PL Received",
            "PL Loss %",
            "PL Duration (s)",
            // Latency Under Load
            "Load Baseline Avg (ms)",
            "Load Under Load Avg (ms)",
            "Load Degradation %",
            "Load Samples",
            // System
            "Battery Start %",
            "Battery End %",
            "Battery Drain %",
            "Peak CPU %",
            "Avg CPU %",
            "Peak Memory (MB)",
            "Thermal State",
        ]

        var rows: [String] = [headers.joined(separator: ",")]

        for r in reports {
            let t = r.results
            let s = t.systemMetrics
            let row: [String] = [
                // Device info
                ISO8601DateFormatter().string(from: r.date),
                csvEscape(r.localDevice.name),
                csvEscape(r.localDevice.displayModel),
                csvEscape(r.localDevice.modelNumber),
                r.localDevice.chipFamily,
                r.localDevice.osVersion,
                csvEscape(r.remoteDevice.name),
                csvEscape(r.remoteDevice.displayModel),
                csvEscape(r.remoteDevice.modelNumber),
                r.remoteDevice.chipFamily,
                r.remoteDevice.osVersion,
                // Overall
                t.overallGrade,
                String(format: "%.1f", r.durationSeconds),
                // Latency
                String(format: "%.2f", t.latencyBurst.min),
                String(format: "%.2f", t.latencyBurst.max),
                String(format: "%.2f", t.latencyBurst.avg),
                String(format: "%.2f", t.latencyBurst.median),
                String(format: "%.2f", t.latencyBurst.p95),
                "\(t.latencyBurst.sampleCount)",
                // Throughput
                String(format: "%.2f", t.sustainedThroughput.bytesPerSecond / 1_000_000),
                "\(t.sustainedThroughput.totalBytes)",
                String(format: "%.2f", t.sustainedThroughput.durationSeconds),
                // Jitter
                String(format: "%.2f", t.jitterMeasurement.averageJitter),
                String(format: "%.2f", t.jitterMeasurement.maxJitter),
                "\(t.jitterMeasurement.sampleCount)",
                // Packet Loss
                "\(t.packetLossStress.sent)",
                "\(t.packetLossStress.received)",
                String(format: "%.1f", t.packetLossStress.lostPercent),
                String(format: "%.2f", t.packetLossStress.durationSeconds),
                // Latency Under Load
                String(format: "%.2f", t.latencyUnderLoad.baselineAvg),
                String(format: "%.2f", t.latencyUnderLoad.underLoadAvg),
                String(format: "%.1f", t.latencyUnderLoad.degradationPercent),
                "\(t.latencyUnderLoad.sampleCount)",
                // System
                s.batteryStart >= 0 ? "\(Int(s.batteryStart * 100))" : "",
                s.batteryEnd >= 0 ? "\(Int(s.batteryEnd * 100))" : "",
                String(format: "%.2f", s.batteryDrainPercent),
                String(format: "%.1f", s.peakCpuUsage),
                String(format: "%.1f", s.avgCpuUsage),
                String(format: "%.0f", s.peakMemoryMB),
                s.thermalStateDuringTest,
            ]
            rows.append(row.joined(separator: ","))
        }

        let csv = rows.joined(separator: "\n")
        let fileName = "iPadDx_Summary_\(reports.count)_reports.csv"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try? csv.write(to: tempURL, atomically: true, encoding: .utf8)
        return tempURL
    }

    // swiftlint:enable function_body_length

    private func csvEscape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }
}
