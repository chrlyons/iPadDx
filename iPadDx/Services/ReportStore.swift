import Foundation
import SwiftData

@MainActor
@Observable
class ReportStore {
    /// Lightweight summaries — always in memory, drives list/analytics views.
    var summaries: [ReportSummary] = []

    /// Human-readable reason the persistent store could not be opened, if it could not.
    /// When this is set the app degrades to "reports unavailable" — nothing on disk is
    /// ever modified or removed, so a later launch (or an app update) can still recover it.
    var initError: String?

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
            // Never delete the store on failure — a transient open error must not cost
            // the user their entire report history.
            initError = "The saved-report database could not be opened: \(error.localizedDescription)"
            AppLog(
                "SwiftData init failed: \(error) — store left on disk untouched, no reports deleted",
                level: .error,
                category: "Store"
            )
        }
        loadAll()
    }

    // MARK: - CRUD

    /// Persists a report and adds it to the in-memory summary list.
    ///
    /// Returns false if the report could not be persisted. The summary is only added
    /// when persistence succeeded — listing a report whose full body can never be
    /// loaded back produces a row that fails to open.
    @discardableResult
    func save(_ report: TestReport, source: String = "local") -> Bool {
        guard let context = modelContext else {
            AppLog(
                "Cannot save report — report storage is unavailable",
                level: .error,
                category: "Store"
            )
            return false
        }

        let entity = ReportEntity(from: report, source: source)
        context.insert(entity)
        do {
            try context.save()
        } catch {
            context.delete(entity)
            AppLog("Failed to save report: \(error)", level: .error, category: "Store")
            return false
        }

        if !summaries.contains(where: { $0.id == report.id }) {
            let summary = ReportSummary(from: report, source: source)
            summaries.insert(summary, at: 0)
        }
        return true
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

    /// Load multiple full reports in a single batch fetch (for export, comparison).
    func loadFullReports(ids: Set<UUID>) -> [TestReport] {
        guard let context = modelContext, !ids.isEmpty else { return [] }
        let idArray = Array(ids)
        let predicate = #Predicate<ReportEntity> { idArray.contains($0.reportID) }
        let descriptor = FetchDescriptor<ReportEntity>(predicate: predicate)
        guard let entities = try? context.fetch(descriptor) else { return [] }
        return entities.compactMap { $0.toTestReport() }
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
        /// Average only over rows that measured each metric — a cancelled or partial
        /// run's zeros would otherwise pull a bridge's figures down and make it look
        /// faster or cleaner than it actually is.
        func mean(_ values: [Double]) -> Double {
            guard !values.isEmpty else { return 0 }
            return values.reduce(0, +) / Double(values.count)
        }
        return grouped.map { bridge, items in
            BridgeComparisonRow(
                bridge: bridge,
                reportCount: items.count,
                avgLatency: mean(items.compactMap(\.measuredLatencyAvg)),
                avgJitter: mean(items.compactMap(\.measuredJitter)),
                avgPacketLoss: mean(items.compactMap(\.measuredPacketLoss)),
                avgThroughput: mean(items.compactMap(\.measuredThroughput)),
                avgGradeScore: mean(items.map { BridgeComparisonRow.gradeScore($0.overallGrade) })
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

    nonisolated func exportCSV(for report: TestReport) -> URL? {
        let r = report.results
        let bridgeLine = report.bridgeTransport.map { "Bridge Transport,\(csvEscape($0))\n" } ?? ""
        let csv = """
        iPadDx Test Report
        Date,\(ISO8601DateFormatter().string(from: report.date))
        Duration,\(String(format: "%.1f", report.durationSeconds))s
        Overall Grade,\(csvEscape(r.overallGrade))
        \(bridgeLine)
        Local Device
        Name,\(csvEscape(report.localDevice.name))
        Model,\(csvEscape(report.localDevice.displayModel))
        Model #,\(csvEscape(report.localDevice.modelNumber))
        Chip,\(csvEscape(report.localDevice.chipFamily))
        OS,\(csvEscape(report.localDevice.osVersion))

        Remote Device
        Name,\(csvEscape(report.remoteDevice.name))
        Model,\(csvEscape(report.remoteDevice.displayModel))
        Model #,\(csvEscape(report.remoteDevice.modelNumber))
        Chip,\(csvEscape(report.remoteDevice.chipFamily))
        OS,\(csvEscape(report.remoteDevice.osVersion))

        Latency Burst (\(r.latencyBurst.sampleCount) samples)
        Min,\(detail(r.hasLatency, "%.2f", r.latencyBurst.min, "ms"))
        Max,\(detail(r.hasLatency, "%.2f", r.latencyBurst.max, "ms"))
        Avg,\(detail(r.hasLatency, "%.2f", r.latencyBurst.avg, "ms"))
        Median,\(detail(r.hasLatency, "%.2f", r.latencyBurst.median, "ms"))
        P95,\(detail(r.hasLatency, "%.2f", r.latencyBurst.p95, "ms"))

        Throughput
        Speed,\(r.hasThroughput ? csvEscape(r.sustainedThroughput.formattedSpeed) : "")
        Bytes,\(r.hasThroughput ? "\(r.sustainedThroughput.totalBytes)" : "")
        Duration,\(detail(r.hasThroughput, "%.2f", r.sustainedThroughput.durationSeconds, "s"))

        Jitter (\(r.jitterMeasurement.sampleCount) samples)
        Average,\(detail(r.hasJitter, "%.2f", r.jitterMeasurement.averageJitter, "ms"))
        Max,\(detail(r.hasJitter, "%.2f", r.jitterMeasurement.maxJitter, "ms"))

        Packet Loss (\(r.packetLossStress.sent) sent)
        Received,\(r.packetLossStress.received)
        Lost,\(detail(r.hasPacketLoss, "%.1f", r.packetLossStress.lostPercent, "%"))
        Duration,\(detail(r.hasPacketLoss, "%.2f", r.packetLossStress.durationSeconds, "s"))

        Latency Under Load (\(r.latencyUnderLoad.sampleCount) samples)
        Baseline Avg,\(detail(r.hasLoadDegradation, "%.2f", r.latencyUnderLoad.baselineAvg, "ms"))
        Under Load Avg,\(detail(r.latencyUnderLoad.sampleCount > 0, "%.2f", r.latencyUnderLoad.underLoadAvg, "ms"))
        Degradation,\(detail(r.hasLoadDegradation, "%.1f", r.latencyUnderLoad.degradationPercent, "%"))

        System Metrics
        Battery Start,\(r.systemMetrics.batteryStart >= 0 ? "\(Int(r.systemMetrics.batteryStart * 100))%" : "N/A")
        Battery End,\(r.systemMetrics.batteryEnd >= 0 ? "\(Int(r.systemMetrics.batteryEnd * 100))%" : "N/A")
        Battery Drain,\(String(format: "%.2f", r.systemMetrics.batteryDrainPercent))%
        Peak CPU,\(String(format: "%.1f", r.systemMetrics.peakCpuUsage))%
        Avg CPU,\(String(format: "%.1f", r.systemMetrics.avgCpuUsage))%
        Peak Memory,\(String(format: "%.0f", r.systemMetrics.peakMemoryMB))MB
        Thermal State,\(csvEscape(r.systemMetrics.thermalStateDuringTest))
        \(report.errors.map { errors in
            "\nErrors (\(errors.count))\n" + errors.enumerated()
                .map { "\($0.offset + 1),\(csvEscape($0.element))" }
                .joined(separator: "\n")
        } ?? "")
        \(report.skippedPhases.map { phases in
            "\nSkipped Phases (\(phases.count))\n" + phases.enumerated()
                .map { "\($0.offset + 1),\(csvEscape($0.element))" }
                .joined(separator: "\n")
        } ?? "")
        """

        let stem = "\(report.localDevice.chipFamily)_vs_\(report.remoteDevice.chipFamily)"
            .replacingOccurrences(of: ",", with: "-")
            .replacingOccurrences(of: "/", with: "-")
        let fileName = "iPadDx_Report_\(stem)_\(report.id.uuidString.prefix(8)).csv"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try? csv.write(to: tempURL, atomically: true, encoding: .utf8)
        return tempURL
    }

    // swiftlint:disable function_body_length
    nonisolated func exportSummaryCSV(for reports: [TestReport]) -> URL? {
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
                csvEscape(r.localDevice.chipFamily),
                csvEscape(r.localDevice.osVersion),
                csvEscape(r.remoteDevice.name),
                csvEscape(r.remoteDevice.displayModel),
                csvEscape(r.remoteDevice.modelNumber),
                csvEscape(r.remoteDevice.chipFamily),
                csvEscape(r.remoteDevice.osVersion),
                csvEscape(r.bridgeTransport ?? "native"),
                csvEscape(t.overallGrade),
                String(format: "%.1f", r.durationSeconds),
                // A phase that measured nothing blanks its WHOLE column group, not
                // just the headline value. Sample counts stay numeric — 0 is a truthful
                // count — but every derived figure is left empty so a spreadsheet reads
                // it as missing rather than averaging a placeholder zero.
                cell(t.hasLatency, "%.2f", t.latencyBurst.min),
                cell(t.hasLatency, "%.2f", t.latencyBurst.max),
                cell(t.hasLatency, "%.2f", t.latencyBurst.avg),
                cell(t.hasLatency, "%.2f", t.latencyBurst.median),
                cell(t.hasLatency, "%.2f", t.latencyBurst.p95),
                "\(t.latencyBurst.sampleCount)",
                cell(t.hasThroughput, "%.2f", t.sustainedThroughput.bytesPerSecond / 1_000_000),
                t.hasThroughput ? "\(t.sustainedThroughput.totalBytes)" : "",
                cell(t.hasThroughput, "%.2f", t.sustainedThroughput.durationSeconds),
                cell(t.hasJitter, "%.2f", t.jitterMeasurement.averageJitter),
                cell(t.hasJitter, "%.2f", t.jitterMeasurement.maxJitter),
                "\(t.jitterMeasurement.sampleCount)",
                "\(t.packetLossStress.sent)",
                "\(t.packetLossStress.received)",
                cell(t.hasPacketLoss, "%.1f", t.packetLossStress.lostPercent),
                cell(t.hasPacketLoss, "%.2f", t.packetLossStress.durationSeconds),
                cell(t.hasLoadDegradation, "%.2f", t.latencyUnderLoad.baselineAvg),
                cell(t.latencyUnderLoad.sampleCount > 0, "%.2f", t.latencyUnderLoad.underLoadAvg),
                cell(t.hasLoadDegradation, "%.1f", t.latencyUnderLoad.degradationPercent),
                "\(t.latencyUnderLoad.sampleCount)",
                s.batteryStart >= 0 ? "\(Int(s.batteryStart * 100))" : "",
                s.batteryEnd >= 0 ? "\(Int(s.batteryEnd * 100))" : "",
                String(format: "%.2f", s.batteryDrainPercent),
                String(format: "%.1f", s.peakCpuUsage),
                String(format: "%.1f", s.avgCpuUsage),
                String(format: "%.0f", s.peakMemoryMB),
                csvEscape(s.thermalStateDuringTest),
                t.responderMetrics.map { String(format: "%.1f", $0.peakCpuUsage) } ?? "",
                t.responderMetrics.map { String(format: "%.1f", $0.avgCpuUsage) } ?? "",
                t.responderMetrics.map { String(format: "%.0f", $0.peakMemoryMB) } ?? "",
                csvEscape(t.responderMetrics?.thermalStateDuringTest ?? ""),
                t.responderMetrics.map { String(format: "%.2f", $0.batteryDrainPercent) } ?? "",
                csvEscape(r.errors?.joined(separator: "; ") ?? ""),
            ]
            rows.append(row.joined(separator: ","))
        }

        let csv = rows.joined(separator: "\n")
        let fileName = "iPadDx_Summary_\(reports.count)_reports_\(ReportExporter.fileStamp()).csv"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try? csv.write(to: tempURL, atomically: true, encoding: .utf8)
        return tempURL
    }

    // swiftlint:enable function_body_length

    // swiftlint:disable function_body_length
    nonisolated func exportAnalyticsCSV(for reports: [TestReport]) -> URL? {
        guard !reports.isEmpty else { return nil }

        var sections: [String] = []

        // Grade distribution is over ALL reports — every report has a grade, including
        // partial ones, so this denominator is correct.
        let count = Double(reports.count)

        /// Section 1: Overview
        ///
        /// Every statistic is computed over reports that ACTUALLY MEASURED the metric.
        /// Disabled and cancelled phases leave zero placeholders, and zero is a
        /// plausible-looking latency/jitter/loss/throughput, so averaging raw fields
        /// silently drags results toward zero. Metrics with no measurements render N/A.
        func stats(_ values: [Double]) -> (avg: String, min: String, max: String, med: String, n: Int) {
            guard !values.isEmpty else { return ("N/A", "N/A", "N/A", "N/A", 0) }
            return (
                f(values.reduce(0, +) / Double(values.count)),
                f(values.min() ?? 0),
                f(values.max() ?? 0),
                f(median(values)),
                values.count
            )
        }

        let latency = stats(reports.compactMap(\.results.measuredLatencyAvg))
        let p95 = stats(reports.compactMap(\.results.measuredLatencyP95))
        let throughput = stats(reports.compactMap { $0.results.measuredThroughput.map { $0 / 1_000_000 } })
        let jitter = stats(reports.compactMap(\.results.measuredJitter))
        let loss = stats(reports.compactMap(\.results.measuredPacketLoss))
        let degradation = stats(reports.compactMap(\.results.measuredLoadDegradation))

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
        Bridge Transports,\(csvEscape(bridges.joined(separator: ", ")))

        Summary
        Metric,Average,Min,Max,Median,Reports Measuring
        Latency Avg (ms),\(latency.avg),\(latency.min),\(latency.max),\(latency.med),\(latency.n)
        Latency P95 (ms),\(p95.avg),\(p95.min),\(p95.max),\(p95.med),\(p95.n)
        Throughput (MB/s),\(throughput.avg),\(throughput.min),\(throughput.max),\(throughput.med),\(throughput.n)
        Jitter Avg (ms),\(jitter.avg),\(jitter.min),\(jitter.max),\(jitter.med),\(jitter.n)
        Packet Loss (%),\(loss.avg),\(loss.min),\(loss.max),\(loss.med),\(loss.n)
        Load Degradation (%),\(degradation.avg),\(degradation.min),\(degradation.max),\(degradation.med),\(degradation
            .n)
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
                    csvEscape(bridge),
                    "\(br.count)",
                    measuredAvg(br) { $0.measuredLatencyAvg },
                    measuredAvg(br) { $0.measuredLatencyP95 },
                    measuredAvg(br) { $0.measuredThroughput.map { $0 / 1_000_000 } },
                    measuredAvg(br) { $0.measuredJitter },
                    measuredAvg(br) { $0.measuredPacketLoss },
                    measuredAvg(br) { $0.measuredLoadDegradation },
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
                        csvEscape(pair), csvEscape(bridge), "\(br.count)",
                        measuredAvg(br) { $0.measuredLatencyAvg },
                        measuredAvg(br) { $0.measuredLatencyP95 },
                        measuredAvg(br) { $0.measuredThroughput.map { $0 / 1_000_000 } },
                        measuredAvg(br) { $0.measuredJitter },
                        measuredAvg(br) { $0.measuredPacketLoss },
                        measuredAvg(br) { $0.measuredLoadDegradation },
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
                    measuredAvg(pairReports) { $0.measuredLatencyAvg },
                    measuredAvg(pairReports) { $0.measuredLatencyP95 },
                    measuredAvg(pairReports) { $0.measuredThroughput.map { $0 / 1_000_000 } },
                    measuredAvg(pairReports) { $0.measuredJitter },
                    measuredAvg(pairReports) { $0.measuredPacketLoss },
                    measuredAvg(pairReports) { $0.measuredLoadDegradation },
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
                    // Counts are of reports that measured latency, matching the figure.
                    let row = [
                        csvEscape(chip), csvEscape(bridge),
                        "\(asSender.filter(\.results.hasLatency).count)",
                        measuredAvg(asSender) { $0.measuredLatencyAvg },
                        "\(asReceiver.filter(\.results.hasLatency).count)",
                        measuredAvg(asReceiver) { $0.measuredLatencyAvg },
                    ]
                    chipRows.append(row.joined(separator: ","))
                }
            }
            sections.append("Per-Chip Summary\n" + chipRows.joined(separator: "\n"))
        } else {
            var chipRows =
                ["Chip,As Sender (count),Sender Avg Latency (ms),As Receiver (count),Receiver Avg Latency (ms)"]
            for chip in chips {
                let asSender = reports.filter { $0.localDevice.chipFamily == chip }
                let asReceiver = reports.filter { $0.remoteDevice.chipFamily == chip }
                let row = [
                    csvEscape(chip),
                    "\(asSender.filter(\.results.hasLatency).count)",
                    measuredAvg(asSender) { $0.measuredLatencyAvg },
                    "\(asReceiver.filter(\.results.hasLatency).count)",
                    measuredAvg(asReceiver) { $0.measuredLatencyAvg },
                ]
                chipRows.append(row.joined(separator: ","))
            }
            sections.append("Per-Chip Summary\n" + chipRows.joined(separator: "\n"))
        }

        // Section 6: Per-OS-pair breakdown (controller OS → responder OS)
        let osGrouped = Dictionary(grouping: reports) {
            "\($0.localDevice.osVersion) \u{2192} \($0.remoteDevice.osVersion)"
        }
        var osPairRows = [
            "OS Pair,Count,Avg Latency (ms),P95 Latency (ms),Throughput (MB/s),Avg Jitter (ms),Packet Loss (%),Load Degradation (%),Fail Rate (%)",
        ]
        for (pair, pairReports) in osGrouped.sorted(by: { $0.key < $1.key }) {
            let n = Double(pairReports.count)
            let failCount = pairReports
                .filter { $0.results.overallGrade == "Poor" || $0.results.overallGrade == "Fair" }.count
            let row = [
                csvEscape(pair), "\(pairReports.count)",
                measuredAvg(pairReports) { $0.measuredLatencyAvg },
                measuredAvg(pairReports) { $0.measuredLatencyP95 },
                measuredAvg(pairReports) { $0.measuredThroughput.map { $0 / 1_000_000 } },
                measuredAvg(pairReports) { $0.measuredJitter },
                measuredAvg(pairReports) { $0.measuredPacketLoss },
                measuredAvg(pairReports) { $0.measuredLoadDegradation },
                f(Double(failCount) / n * 100),
            ]
            osPairRows.append(row.joined(separator: ","))
        }
        sections.append("Per-OS-Pair Breakdown\n" + osPairRows.joined(separator: "\n"))

        // Section 7: Failed tests
        let failed = reports.filter { $0.results.latencyBurst.sampleCount == 0 }
        if !failed.isEmpty {
            var failRows = ["Date,Local,Remote,Bridge,Grade,Errors,Skipped Phases"]
            for r in failed {
                let row = [
                    ISO8601DateFormatter().string(from: r.date),
                    csvEscape(r.localDevice.shortDescription),
                    csvEscape(r.remoteDevice.shortDescription),
                    csvEscape(r.bridgeTransport ?? "native"),
                    csvEscape(r.results.overallGrade),
                    csvEscape(r.errors?.joined(separator: "; ") ?? ""),
                    csvEscape(r.skippedPhases?.joined(separator: "; ") ?? ""),
                ]
                failRows.append(row.joined(separator: ","))
            }
            sections.append("Failed Tests (\(failed.count))\n" + failRows.joined(separator: "\n"))
        }

        let csv = sections.joined(separator: "\n\n")
        let fileName = "iPadDx_Analytics_\(reports.count)_reports_\(ReportExporter.fileStamp()).csv"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try? csv.write(to: tempURL, atomically: true, encoding: .utf8)
        return tempURL
    }

    // swiftlint:enable function_body_length

    /// Formats the mean of the reports that ACTUALLY MEASURED a metric, or "N/A".
    ///
    /// Cancelled and partial runs persist zero placeholders, and zero reads as a real
    /// latency/jitter/loss/throughput, so every per-pair, per-chip, per-OS and
    /// per-bridge breakdown must filter rather than average the raw field.
    nonisolated private func measuredAvg(
        _ reports: [TestReport],
        _ metric: (TestSuiteResults) -> Double?
    ) -> String {
        let values = reports.compactMap { metric($0.results) }
        guard !values.isEmpty else { return "N/A" }
        return f(values.reduce(0, +) / Double(values.count))
    }

    /// A formatted value with its unit, or a blank cell when the phase measured nothing.
    nonisolated private func detail(
        _ measured: Bool, _ format: String, _ value: Double, _ unit: String
    ) -> String {
        measured ? String(format: format, value) + unit : ""
    }

    /// A formatted value, or a blank cell when the owning phase measured nothing.
    nonisolated private func cell(_ measured: Bool, _ format: String, _ value: Double) -> String {
        measured ? String(format: format, value) : ""
    }

    nonisolated private func f(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    nonisolated private func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    /// Single shared escaping rule for every CSV field this app writes.
    nonisolated private func csvEscape(_ value: String) -> String {
        ReportExporter.csvEscape(value)
    }
}
