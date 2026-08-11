import Foundation

enum ExportFormat: String, CaseIterable, Identifiable {
    case csv = "CSV"
    case json = "JSON"
    case pdf = "PDF"

    var id: String {
        rawValue
    }

    var fileExtension: String {
        switch self {
        case .csv: "csv"
        case .json: "json"
        case .pdf: "pdf"
        }
    }

    var icon: String {
        switch self {
        case .csv: "tablecells"
        case .json: "curlybraces"
        case .pdf: "doc.richtext"
        }
    }
}

enum ReportExporter {
    /// Export reports to JSON with full fidelity.
    static func exportJSON(reports: [TestReport]) throws -> URL {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(reports)

        let fileName = reports.count == 1
            ? "iPadDx-Report-\(fileStamp()).json"
            : "iPadDx-Reports-\(reports.count)-\(fileStamp()).json"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try data.write(to: url)
        return url
    }

    /// Export a single report to JSON.
    static func exportSingleJSON(report: TestReport) throws -> URL {
        try exportJSON(reports: [report])
    }

    /// Export exactly one report in the requested format.
    /// JSON goes through the dedicated single-report path so the payload is a
    /// one-element array with a single-report filename.
    static func exportSingle(report: TestReport, format: ExportFormat) throws -> URL {
        switch format {
        case .json: try exportSingleJSON(report: report)
        case .csv: try exportCSV(reports: [report])
        case .pdf: try exportPDF(reports: [report])
        }
    }

    /// Shown in place of a value a run never measured. Pasting "0.0ms" into a ticket
    /// or a message reads as an excellent result rather than as missing data.
    private static let notMeasured = "not measured"

    /// Generate a clipboard-friendly summary string.
    ///
    /// Covers ALL SEVEN phases. Listing only latency, throughput, jitter and packet loss
    /// meant a run configured with just DNS Resolution, Latency Under Load or Heavy Load
    /// copied as if it had measured nothing at all.
    static func clipboardSummary(report: TestReport) -> String {
        let r = report.results
        return """
        iPadDx Report — \(report.localDevice.name) ↔ \(report.remoteDevice.name)
        Date: \(ISO8601DateFormatter().string(from: report.date))
        Grade: \(r.overallGrade)
        Bridge: \(report.bridgeTransport ?? "native")
        Link: \(report.results.linkConditions?.summary ?? "Unknown")
        DNS Resolution: \(dnsSummary(r))
        Latency: \(r.hasLatency ? "avg \(f(r.latencyBurst.avg))ms, p95 \(f(r.latencyBurst.p95))ms" : notMeasured)
        Throughput: \(r.hasThroughput ? r.sustainedThroughput.formattedSpeed : notMeasured)
        Jitter: \(r.hasJitter ? "\(f(r.jitterMeasurement.averageJitter))ms" : notMeasured)
        Packet Loss: \(r.hasPacketLoss ? "\(f(r.packetLossStress.lostPercent))%" : notMeasured)
        Latency Under Load: \(underLoadSummary(r))
        Heavy Load: \(heavyLoadSummary(r))
        Duration: \(f(report.durationSeconds))s
        """
    }

    /// Phase 0 — the time taken to resolve the peer's Bonjour service.
    private static func dnsSummary(_ r: TestSuiteResults) -> String {
        guard r.hasDNSResolution, let dns = r.dnsResolution else { return notMeasured }
        return "\(f(dns.resolutionTimeMs))ms"
    }

    /// Phase 5 — degradation additionally needs a baseline to compare against, so a run
    /// that probed under load without one still reports the measurement it does have.
    private static func underLoadSummary(_ r: TestSuiteResults) -> String {
        guard r.hasLatencyUnderLoad else { return notMeasured }
        let avg = "avg \(f(r.latencyUnderLoad.underLoadAvg))ms"
        guard r.hasLoadDegradation else { return avg }
        return "\(avg), \(r.latencyUnderLoad.formattedDegradation)"
    }

    /// Phase 6.
    private static func heavyLoadSummary(_ r: TestSuiteResults) -> String {
        guard r.hasHeavyLoad, let heavy = r.heavyLoad else { return notMeasured }
        return "avg \(f(heavy.avgLatency))ms, \(heavy.formattedThroughput), \(f(heavy.packetLoss))% loss"
    }

    /// Batch export: returns URLs for all formats requested.
    static func exportBatch(
        reports: [TestReport],
        format: ExportFormat
    ) throws -> [URL] {
        switch format {
        case .json:
            try [exportJSON(reports: reports)]
        case .csv:
            try [exportCSV(reports: reports)]
        case .pdf:
            try [exportPDF(reports: reports)]
        }
    }

    // MARK: - CSV

    static func exportCSV(reports: [TestReport]) throws -> URL {
        let headers = [
            "Date", "Local Device", "Remote Device", "Local Chip", "Remote Chip", "Bridge", "Grade",
            "Latency Avg (ms)", "Latency P95 (ms)", "Throughput (B/s)", "Jitter (ms)",
            "Packet Loss (%)",
            "Under Load Baseline (ms)", "Under Load Avg (ms)", "Load Degradation (%)",
            "Duration (s)",
            "Link", "Interface", "Direct P2P", "Link Changes", "Disconnects", "Discovery Flaps", "SSID",
        ]
        var rows: [String] = [headers.joined(separator: ",")]

        let df = ISO8601DateFormatter()
        for r in reports {
            // Every string field is escaped: device names may contain quotes or commas,
            // and an unrecognised iPad falls back to a raw identifier like "iPad16,3".
            // Split into typed sub-arrays: as one 23-element literal with mixed
            // optional-map expressions the type checker gives up
            // ("unable to type-check this expression in reasonable time").
            let identity: [String] = [
                df.string(from: r.date),
                csvEscape(r.localDevice.name),
                csvEscape(r.remoteDevice.name),
                csvEscape(r.localDevice.chipFamily),
                csvEscape(r.remoteDevice.chipFamily),
                csvEscape(r.bridgeTransport ?? "native"),
                csvEscape(r.results.overallGrade),
            ]
            // Blank, not zero, when a phase never measured: a spreadsheet treats
            // an empty cell as missing but would average a 0 as a real reading.
            let metrics: [String] = [
                r.results.measuredLatencyAvg.map(f) ?? "",
                r.results.measuredLatencyP95.map(f) ?? "",
                r.results.measuredThroughput.map(f) ?? "",
                r.results.measuredJitter.map(f) ?? "",
                r.results.measuredPacketLoss.map(f) ?? "",
                // The under-load pair is blank unless the phase probed, and degradation
                // additionally needs a baseline — a 0% degradation cell would read as
                // "load made no difference" rather than "never measured".
                r.results.hasLoadDegradation ? f(r.results.latencyUnderLoad.baselineAvg) : "",
                r.results.hasLatencyUnderLoad ? f(r.results.latencyUnderLoad.underLoadAvg) : "",
                r.results.measuredLoadDegradation.map(f) ?? "",
                f(r.durationSeconds),
            ]
            let link: [String] = [
                csvEscape(r.results.linkConditions?.summary ?? "Unknown"),
                csvEscape(r.results.linkConditions?.interfaceName ?? ""),
                (r.results.linkConditions?.usedPeerToPeer ?? false) ? "yes" : "no",
                String(r.results.linkConditions?.pathChanges ?? 0),
                String(r.results.linkConditions?.disconnects.count ?? 0),
                String(r.results.linkConditions?.discoveryFlaps ?? 0),
                csvEscape(r.results.linkConditions?.ssid ?? ""),
            ]
            rows.append((identity + metrics + link).joined(separator: ","))
        }

        let csv = rows.joined(separator: "\n") + "\n"
        let fileName = reports.count == 1
            ? "iPadDx-Report-\(fileStamp()).csv"
            : "iPadDx-Reports-\(reports.count)-\(fileStamp()).csv"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try csv.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - PDF

    static func exportPDF(reports: [TestReport]) throws -> URL {
        guard let url = AnalyticsReportRenderer.renderPDF(reports: reports) else {
            throw NSError(
                domain: "ReportExporter",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "PDF generation failed"]
            )
        }
        return url
    }

    // MARK: - Helpers

    /// The one CSV escaping rule used by every CSV this app writes.
    /// Always quotes, doubles embedded quotes, and therefore also survives
    /// embedded commas and newlines.
    static func csvEscape(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    /// Second-resolution timestamp plus a short random suffix, so two exports of
    /// the same kind in the same second still land on distinct files.
    static func fileStamp() -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd-HHmmss"
        return "\(df.string(from: Date()))-\(UUID().uuidString.prefix(4))"
    }

    private static func f(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}
