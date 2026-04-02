import Foundation
import SwiftData

@MainActor
@Observable
class ReportStore {
    /// Lightweight summaries — always in memory, drives list/analytics views.
    var summaries: [ReportSummary] = []

    private var modelContainer: ModelContainer?
    private var modelContext: ModelContext?

    init() {
        do {
            let schema = Schema([ReportEntity.self])
            let config = ModelConfiguration("iPadDxReports", isStoredInMemoryOnly: false)
            modelContainer = try ModelContainer(
                for: schema,
                migrationPlan: nil,
                configurations: [config]
            )
            modelContext = modelContainer.map { ModelContext($0) }
        } catch {
            AppLog("SwiftData init failed: \(error), deleting old store and retrying", level: .error, category: "Store")
            if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                let fm = FileManager.default
                let files = (try? fm.contentsOfDirectory(at: appSupport, includingPropertiesForKeys: nil)) ?? []
                for file in files where file.lastPathComponent.hasPrefix("iPadDxReports") {
                    AppLog("Deleting: \(file.lastPathComponent)", level: .warning, category: "Store")
                    try? fm.removeItem(at: file)
                }
            }
            do {
                let config = ModelConfiguration("iPadDxReports", isStoredInMemoryOnly: false)
                modelContainer = try ModelContainer(for: ReportEntity.self, configurations: config)
                modelContext = modelContainer.map { ModelContext($0) }
                AppLog("Fresh database created successfully", category: "Store")
            } catch {
                AppLog("SwiftData fallback also failed: \(error)", level: .error, category: "Store")
            }
        }
        loadAll()
    }

    // MARK: - CRUD

    func save(_ report: TestReport, source: String = "local") {
        if let context = modelContext {
            let entity = ReportEntity(from: report, source: source)
            context.insert(entity)
            try? context.save()
        }

        if !summaries.contains(where: { $0.id == report.id }) {
            let summary = ReportSummary(from: report, source: source)
            summaries.insert(summary, at: 0)
        }
    }

    func delete(_ id: UUID) {
        if let context = modelContext {
            let predicate = #Predicate<ReportEntity> { $0.reportID == id }
            let descriptor = FetchDescriptor<ReportEntity>(predicate: predicate)
            if let entities = try? context.fetch(descriptor) {
                for entity in entities {
                    context.delete(entity)
                }
                try? context.save()
            }
        }
        summaries.removeAll { $0.id == id }
    }

    func delete(_ report: TestReport) {
        delete(report.id)
    }

    func loadAll() {
        guard let context = modelContext else { return }
        let descriptor = FetchDescriptor<ReportEntity>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        guard let entities = try? context.fetch(descriptor) else { return }
        summaries = entities.map { $0.toSummary() }
    }

    /// Load full report on demand (detail view, export, comparison).
    func loadFullReport(id: UUID) -> TestReport? {
        guard let context = modelContext else { return nil }
        let predicate = #Predicate<ReportEntity> { $0.reportID == id }
        let descriptor = FetchDescriptor<ReportEntity>(predicate: predicate)
        guard let entity = try? context.fetch(descriptor).first else { return nil }
        return entity.toTestReport()
    }

    /// Load multiple full reports (for export, comparison).
    func loadFullReports(ids: Set<UUID>) -> [TestReport] {
        ids.compactMap { loadFullReport(id: $0) }
    }

    /// Load all full reports matching current summaries (for export).
    func loadAllFullReports() -> [TestReport] {
        loadFullReports(ids: Set(summaries.map(\.id)))
    }

    // MARK: - Queries (on summaries)

    func summaries(forChipPair local: String, remote: String, bridge: String? = nil) -> [ReportSummary] {
        summaries.filter {
            $0.localChip == local &&
                $0.remoteChip == remote &&
                (bridge == nil || $0.bridgeTransport == bridge)
        }
    }

    /// All summaries for a given bridge transport.
    func summaries(forBridge bridge: String) -> [ReportSummary] {
        summaries.filter { $0.bridgeTransport == bridge }
    }

    /// All distinct bridge transports that have saved reports.
    func availableBridgeTransports() -> [String] {
        Array(Set(summaries.map(\.bridgeTransport))).sorted()
    }

    /// Compare metrics across bridges for the same device pair.
    func bridgeComparison(local: String, remote: String) -> [BridgeComparisonRow] {
        let pairSummaries = summaries(forChipPair: local, remote: remote)
        let grouped = Dictionary(grouping: pairSummaries) { $0.bridgeTransport }
        return grouped.map { bridge, items in
            let n = Double(items.count)
            return BridgeComparisonRow(
                bridge: bridge,
                reportCount: items.count,
                avgLatency: items.map(\.latencyAvg).reduce(0, +) / n,
                avgJitter: items.map(\.jitterAvg).reduce(0, +) / n,
                avgPacketLoss: items.map(\.packetLossPercent).reduce(0, +) / n,
                avgThroughput: items.map(\.throughputBps).reduce(0, +) / n,
                avgGradeScore: items.map { BridgeComparisonRow.gradeScore($0.overallGrade) }.reduce(0, +) / n
            )
        }.sorted { $0.bridge < $1.bridge }
    }

    func reports(fromSource source: String, bridge: String? = nil) -> [TestReport] {
        guard let context = modelContext else { return [] }
        let descriptor: FetchDescriptor<ReportEntity>
        if let bridge {
            let predicate = #Predicate<ReportEntity> {
                $0.source == source && $0.bridgeTransport == bridge
            }
            descriptor = FetchDescriptor(
                predicate: predicate,
                sortBy: [SortDescriptor(\.date, order: .reverse)]
            )
        } else {
            let predicate = #Predicate<ReportEntity> { $0.source == source }
            descriptor = FetchDescriptor(
                predicate: predicate,
                sortBy: [SortDescriptor(\.date, order: .reverse)]
            )
        }
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
        guard !summaries.contains(where: { $0.id == report.id }) else { return }
        save(report, source: "remote")
    }

    // MARK: - Export

    func exportCSV(for report: TestReport) -> URL? {
        let r = report.results
        let bridgeLine = report.bridgeTransport.map { "Bridge Transport,\($0)\n" } ?? ""
        let csv = """
        iPadDx Test Report
        Date,\(ISO8601DateFormatter().string(from: report.date))
        Duration,\(String(format: "%.1f", report.durationSeconds))s
        Overall Grade,\(r.overallGrade)
        \(bridgeLine)
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
        \(report.errors.map { errors in
            "\nErrors (\(errors.count))\n" + errors.enumerated().map { "\($0.offset + 1),\($0.element)" }
                .joined(separator: "\n")
        } ?? "")
        """

        let fileName = "iPadDx_Report_\(report.localDevice.chipFamily)_vs_\(report.remoteDevice.chipFamily)_\(report.id.uuidString.prefix(8)).csv"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try? csv.write(to: tempURL, atomically: true, encoding: .utf8)
        return tempURL
    }

    // swiftlint:disable function_body_length
    func exportSummaryCSV(for reports: [TestReport]) -> URL? {
        let headers = [
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
            "Bridge Transport",
            "Grade",
            "Duration (s)",
            "Latency Min (ms)",
            "Latency Max (ms)",
            "Latency Avg (ms)",
            "Latency Median (ms)",
            "Latency P95 (ms)",
            "Latency Samples",
            "Throughput (MB/s)",
            "Throughput Bytes",
            "Throughput Duration (s)",
            "Jitter Avg (ms)",
            "Jitter Max (ms)",
            "Jitter Samples",
            "PL Sent",
            "PL Received",
            "PL Loss %",
            "PL Duration (s)",
            "Load Baseline Avg (ms)",
            "Load Under Load Avg (ms)",
            "Load Degradation %",
            "Load Samples",
            "Battery Start %",
            "Battery End %",
            "Battery Drain %",
            "Peak CPU %",
            "Avg CPU %",
            "Peak Memory (MB)",
            "Thermal State",
            "Resp Peak CPU %",
            "Resp Avg CPU %",
            "Resp Peak Memory (MB)",
            "Resp Thermal State",
            "Resp Battery Drain %",
            "Errors",
        ]

        var rows: [String] = [headers.joined(separator: ",")]

        for r in reports {
            let t = r.results
            let s = t.systemMetrics
            let row: [String] = [
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
                r.bridgeTransport ?? "native",
                t.overallGrade,
                String(format: "%.1f", r.durationSeconds),
                String(format: "%.2f", t.latencyBurst.min),
                String(format: "%.2f", t.latencyBurst.max),
                String(format: "%.2f", t.latencyBurst.avg),
                String(format: "%.2f", t.latencyBurst.median),
                String(format: "%.2f", t.latencyBurst.p95),
                "\(t.latencyBurst.sampleCount)",
                String(format: "%.2f", t.sustainedThroughput.bytesPerSecond / 1_000_000),
                "\(t.sustainedThroughput.totalBytes)",
                String(format: "%.2f", t.sustainedThroughput.durationSeconds),
                String(format: "%.2f", t.jitterMeasurement.averageJitter),
                String(format: "%.2f", t.jitterMeasurement.maxJitter),
                "\(t.jitterMeasurement.sampleCount)",
                "\(t.packetLossStress.sent)",
                "\(t.packetLossStress.received)",
                String(format: "%.1f", t.packetLossStress.lostPercent),
                String(format: "%.2f", t.packetLossStress.durationSeconds),
                String(format: "%.2f", t.latencyUnderLoad.baselineAvg),
                String(format: "%.2f", t.latencyUnderLoad.underLoadAvg),
                String(format: "%.1f", t.latencyUnderLoad.degradationPercent),
                "\(t.latencyUnderLoad.sampleCount)",
                s.batteryStart >= 0 ? "\(Int(s.batteryStart * 100))" : "",
                s.batteryEnd >= 0 ? "\(Int(s.batteryEnd * 100))" : "",
                String(format: "%.2f", s.batteryDrainPercent),
                String(format: "%.1f", s.peakCpuUsage),
                String(format: "%.1f", s.avgCpuUsage),
                String(format: "%.0f", s.peakMemoryMB),
                s.thermalStateDuringTest,
                t.responderMetrics.map { String(format: "%.1f", $0.peakCpuUsage) } ?? "",
                t.responderMetrics.map { String(format: "%.1f", $0.avgCpuUsage) } ?? "",
                t.responderMetrics.map { String(format: "%.0f", $0.peakMemoryMB) } ?? "",
                t.responderMetrics?.thermalStateDuringTest ?? "",
                t.responderMetrics.map { String(format: "%.2f", $0.batteryDrainPercent) } ?? "",
                csvEscape(r.errors?.joined(separator: "; ") ?? ""),
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

    // swiftlint:disable function_body_length
    func exportAnalyticsCSV(for reports: [TestReport]) -> URL? {
        guard !reports.isEmpty else { return nil }

        var sections: [String] = []

        // Section 1: Overview
        let count = Double(reports.count)
        let avgLatency = reports.map(\.results.latencyBurst.avg).reduce(0, +) / count
        let avgP95 = reports.map(\.results.latencyBurst.p95).reduce(0, +) / count
        let avgThroughput = reports.map(\.results.sustainedThroughput.bytesPerSecond).reduce(0, +) / count / 1_000_000
        let avgJitter = reports.map(\.results.jitterMeasurement.averageJitter).reduce(0, +) / count
        let avgLoss = reports.map(\.results.packetLossStress.lostPercent).reduce(0, +) / count
        let avgDegradation = reports.map(\.results.latencyUnderLoad.degradationPercent).reduce(0, +) / count

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .short
        dateFormatter.timeStyle = .short
        let earliest = reports.map(\.date).min()!
        let latest = reports.map(\.date).max()!

        let bridges = Array(Set(reports.map { $0.bridgeTransport ?? "native" })).sorted()

        sections.append("""
        iPadDx Analytics Report
        Generated,\(dateFormatter.string(from: Date()))
        Date Range,\(dateFormatter.string(from: earliest)) — \(dateFormatter.string(from: latest))
        Total Reports,\(reports.count)
        Bridge Transports,"\(bridges.joined(separator: ", "))"

        Summary
        Metric,Average,Min,Max,Median
        Latency Avg (ms),\(f(avgLatency)),\(f(reports.map(\.results.latencyBurst.avg).min() ?? 0)),\(f(reports
                .map(\.results.latencyBurst.avg).max() ?? 0)),\(f(median(reports.map(\.results.latencyBurst.avg))))
        Latency P95 (ms),\(f(avgP95)),\(f(reports.map(\.results.latencyBurst.p95).min() ?? 0)),\(f(reports
                .map(\.results.latencyBurst.p95).max() ?? 0)),\(f(median(reports.map(\.results.latencyBurst.p95))))
        Throughput (MB/s),\(f(avgThroughput)),\(f((reports.map(\.results.sustainedThroughput.bytesPerSecond)
                .min() ?? 0) / 1_000_000)),\(f((reports.map(\.results.sustainedThroughput.bytesPerSecond).max() ?? 0) /
                1_000_000)),\(f(median(reports.map { $0.results.sustainedThroughput.bytesPerSecond / 1_000_000 })))
        Jitter Avg (ms),\(f(avgJitter)),\(f(reports.map(\.results.jitterMeasurement.averageJitter)
                .min() ?? 0)),\(f(reports.map(\.results.jitterMeasurement.averageJitter)
                .max() ?? 0)),\(f(median(reports.map(\.results.jitterMeasurement.averageJitter))))
        Packet Loss (%),\(f(avgLoss)),\(f(reports.map(\.results.packetLossStress.lostPercent).min() ?? 0)),\(f(reports
                .map(\.results.packetLossStress.lostPercent)
                .max() ?? 0)),\(f(median(reports.map(\.results.packetLossStress.lostPercent))))
        Load Degradation (%),\(f(avgDegradation)),\(f(reports.map(\.results.latencyUnderLoad.degradationPercent)
                .min() ?? 0)),\(f(reports.map(\.results.latencyUnderLoad.degradationPercent)
                .max() ?? 0)),\(f(median(reports.map(\.results.latencyUnderLoad.degradationPercent))))
        """)

        // Section 2: Grade distribution
        let grades = ["Excellent", "Good", "Fair", "Poor"]
        let gradeCounts = grades.map { grade in reports.filter { $0.results.overallGrade == grade }.count }
        sections.append("""
        Grade Distribution
        Grade,Count,Percent
        \(grades.enumerated()
            .map { "\($0.element),\(gradeCounts[$0.offset]),\(f(Double(gradeCounts[$0.offset]) / count * 100))%" }
            .joined(separator: "\n"))
        """)

        // Section 3: Bridge Comparison (only if multiple bridges)
        if bridges.count > 1 {
            var bridgeRows = [
                "Bridge,Reports,Avg Latency (ms),P95 Latency (ms),Throughput (MB/s),Avg Jitter (ms),Packet Loss (%),Load Degradation (%),Excellent,Good,Fair,Poor",
            ]
            for bridge in bridges {
                let br = reports.filter { ($0.bridgeTransport ?? "native") == bridge }
                let bn = Double(br.count)
                guard bn > 0 else { continue }
                let row = [
                    bridge,
                    "\(br.count)",
                    f(br.map(\.results.latencyBurst.avg).reduce(0, +) / bn),
                    f(br.map(\.results.latencyBurst.p95).reduce(0, +) / bn),
                    f(br.map(\.results.sustainedThroughput.bytesPerSecond).reduce(0, +) / bn / 1_000_000),
                    f(br.map(\.results.jitterMeasurement.averageJitter).reduce(0, +) / bn),
                    f(br.map(\.results.packetLossStress.lostPercent).reduce(0, +) / bn),
                    f(br.map(\.results.latencyUnderLoad.degradationPercent).reduce(0, +) / bn),
                    "\(br.filter { $0.results.overallGrade == "Excellent" }.count)",
                    "\(br.filter { $0.results.overallGrade == "Good" }.count)",
                    "\(br.filter { $0.results.overallGrade == "Fair" }.count)",
                    "\(br.filter { $0.results.overallGrade == "Poor" }.count)",
                ]
                bridgeRows.append(row.joined(separator: ","))
            }
            sections.append("Bridge Comparison\n" + bridgeRows.joined(separator: "\n"))
        }

        // Section 4: Per-pair breakdown (with bridge column)
        let grouped = Dictionary(grouping: reports) {
            "\($0.localDevice.chipFamily) vs \($0.remoteDevice.chipFamily)"
        }
        var pairRows: [String]
        if bridges.count > 1 {
            pairRows = [
                "Pair,Bridge,Count,Avg Latency (ms),P95 Latency (ms),Throughput (MB/s),Avg Jitter (ms),Packet Loss (%),Load Degradation (%),Excellent,Good,Fair,Poor",
            ]
            for (pair, pairReports) in grouped.sorted(by: { $0.key < $1.key }) {
                let byBridge = Dictionary(grouping: pairReports) { $0.bridgeTransport ?? "native" }
                for bridge in byBridge.keys.sorted() {
                    let br = byBridge[bridge]!
                    let n = Double(br.count)
                    let row = [
                        csvEscape(pair), bridge, "\(br.count)",
                        f(br.map(\.results.latencyBurst.avg).reduce(0, +) / n),
                        f(br.map(\.results.latencyBurst.p95).reduce(0, +) / n),
                        f(br.map(\.results.sustainedThroughput.bytesPerSecond).reduce(0, +) / n / 1_000_000),
                        f(br.map(\.results.jitterMeasurement.averageJitter).reduce(0, +) / n),
                        f(br.map(\.results.packetLossStress.lostPercent).reduce(0, +) / n),
                        f(br.map(\.results.latencyUnderLoad.degradationPercent).reduce(0, +) / n),
                        "\(br.filter { $0.results.overallGrade == "Excellent" }.count)",
                        "\(br.filter { $0.results.overallGrade == "Good" }.count)",
                        "\(br.filter { $0.results.overallGrade == "Fair" }.count)",
                        "\(br.filter { $0.results.overallGrade == "Poor" }.count)",
                    ]
                    pairRows.append(row.joined(separator: ","))
                }
            }
        } else {
            pairRows = [
                "Pair,Count,Avg Latency (ms),P95 Latency (ms),Throughput (MB/s),Avg Jitter (ms),Packet Loss (%),Load Degradation (%),Excellent,Good,Fair,Poor",
            ]
            for (pair, pairReports) in grouped.sorted(by: { $0.key < $1.key }) {
                let n = Double(pairReports.count)
                let row = [
                    csvEscape(pair), "\(pairReports.count)",
                    f(pairReports.map(\.results.latencyBurst.avg).reduce(0, +) / n),
                    f(pairReports.map(\.results.latencyBurst.p95).reduce(0, +) / n),
                    f(pairReports.map(\.results.sustainedThroughput.bytesPerSecond).reduce(0, +) / n / 1_000_000),
                    f(pairReports.map(\.results.jitterMeasurement.averageJitter).reduce(0, +) / n),
                    f(pairReports.map(\.results.packetLossStress.lostPercent).reduce(0, +) / n),
                    f(pairReports.map(\.results.latencyUnderLoad.degradationPercent).reduce(0, +) / n),
                    "\(pairReports.filter { $0.results.overallGrade == "Excellent" }.count)",
                    "\(pairReports.filter { $0.results.overallGrade == "Good" }.count)",
                    "\(pairReports.filter { $0.results.overallGrade == "Fair" }.count)",
                    "\(pairReports.filter { $0.results.overallGrade == "Poor" }.count)",
                ]
                pairRows.append(row.joined(separator: ","))
            }
        }
        sections.append("Per-Pair Breakdown\n" + pairRows.joined(separator: "\n"))

        // Section 5: Per-chip summary (with bridge dimension if multiple)
        let chips = Set(reports.flatMap { [$0.localDevice.chipFamily, $0.remoteDevice.chipFamily] }).sorted()
        if bridges.count > 1 {
            var chipRows =
                ["Chip,Bridge,As Sender (count),Sender Avg Latency (ms),As Receiver (count),Receiver Avg Latency (ms)"]
            for chip in chips {
                for bridge in bridges {
                    let asSender = reports
                        .filter { $0.localDevice.chipFamily == chip && ($0.bridgeTransport ?? "native") == bridge }
                    let asReceiver = reports
                        .filter { $0.remoteDevice.chipFamily == chip && ($0.bridgeTransport ?? "native") == bridge }
                    let senderAvg = asSender.isEmpty ? 0 : asSender.map(\.results.latencyBurst.avg)
                        .reduce(0, +) / Double(asSender.count)
                    let receiverAvg = asReceiver.isEmpty ? 0 : asReceiver.map(\.results.latencyBurst.avg)
                        .reduce(0, +) / Double(asReceiver.count)
                    chipRows
                        .append(
                            "\(chip),\(bridge),\(asSender.count),\(f(senderAvg)),\(asReceiver.count),\(f(receiverAvg))"
                        )
                }
            }
            sections.append("Per-Chip Summary\n" + chipRows.joined(separator: "\n"))
        } else {
            var chipRows =
                ["Chip,As Sender (count),Sender Avg Latency (ms),As Receiver (count),Receiver Avg Latency (ms)"]
            for chip in chips {
                let asSender = reports.filter { $0.localDevice.chipFamily == chip }
                let asReceiver = reports.filter { $0.remoteDevice.chipFamily == chip }
                let senderAvg = asSender.isEmpty ? 0 : asSender.map(\.results.latencyBurst.avg)
                    .reduce(0, +) / Double(asSender.count)
                let receiverAvg = asReceiver.isEmpty ? 0 : asReceiver.map(\.results.latencyBurst.avg)
                    .reduce(0, +) / Double(asReceiver.count)
                chipRows.append("\(chip),\(asSender.count),\(f(senderAvg)),\(asReceiver.count),\(f(receiverAvg))")
            }
            sections.append("Per-Chip Summary\n" + chipRows.joined(separator: "\n"))
        }

        // Section 6: Failed tests
        let failed = reports.filter { $0.results.latencyBurst.sampleCount == 0 }
        if !failed.isEmpty {
            var failRows = ["Date,Local,Remote,Bridge,Grade,Errors"]
            for r in failed {
                failRows
                    .append(
                        "\(ISO8601DateFormatter().string(from: r.date)),\(csvEscape(r.localDevice.shortDescription)),\(csvEscape(r.remoteDevice.shortDescription)),\(r.bridgeTransport ?? "native"),\(r.results.overallGrade),\(csvEscape(r.errors?.joined(separator: "; ") ?? ""))"
                    )
            }
            sections.append("Failed Tests (\(failed.count))\n" + failRows.joined(separator: "\n"))
        }

        let csv = sections.joined(separator: "\n\n")
        let fileName = "iPadDx_Analytics_\(reports.count)_reports.csv"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try? csv.write(to: tempURL, atomically: true, encoding: .utf8)
        return tempURL
    }

    // swiftlint:enable function_body_length

    private func f(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    private func csvEscape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }
}
