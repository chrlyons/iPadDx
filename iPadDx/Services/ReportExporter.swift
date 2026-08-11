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

    /// Generate a clipboard-friendly summary string.
    static func clipboardSummary(report: TestReport) -> String {
        let r = report.results
        return """
        iPadDx Report — \(report.localDevice.name) ↔ \(report.remoteDevice.name)
        Date: \(ISO8601DateFormatter().string(from: report.date))
        Grade: \(r.overallGrade)
        Bridge: \(report.bridgeTransport ?? "native")
        Link: \(report.results.linkConditions?.summary ?? "Unknown")
        Latency: avg \(f(r.latencyBurst.avg))ms, p95 \(f(r.latencyBurst.p95))ms
        Throughput: \(r.sustainedThroughput.formattedSpeed)
        Jitter: \(f(r.jitterMeasurement.averageJitter))ms
        Packet Loss: \(f(r.packetLossStress.lostPercent))%
        Duration: \(f(report.durationSeconds))s
        """
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
            "Packet Loss (%)", "Duration (s)",
            "Link", "Interface", "Direct P2P", "Link Changes", "Disconnects", "Discovery Flaps", "SSID",
        ]
        var rows: [String] = [headers.joined(separator: ",")]

        let df = ISO8601DateFormatter()
        for r in reports {
            // Every string field is escaped: device names may contain quotes or commas,
            // and an unrecognised iPad falls back to a raw identifier like "iPad16,3".
            let row = [
                df.string(from: r.date),
                csvEscape(r.localDevice.name),
                csvEscape(r.remoteDevice.name),
                csvEscape(r.localDevice.chipFamily),
                csvEscape(r.remoteDevice.chipFamily),
                csvEscape(r.bridgeTransport ?? "native"),
                csvEscape(r.results.overallGrade),
                f(r.results.latencyBurst.avg),
                f(r.results.latencyBurst.p95),
                f(r.results.sustainedThroughput.bytesPerSecond),
                f(r.results.jitterMeasurement.averageJitter),
                f(r.results.packetLossStress.lostPercent),
                f(r.durationSeconds),
                csvEscape(r.results.linkConditions?.summary ?? "Unknown"),
                csvEscape(r.results.linkConditions?.interfaceName ?? ""),
                (r.results.linkConditions?.usedPeerToPeer ?? false) ? "yes" : "no",
                String(r.results.linkConditions?.pathChanges ?? 0),
                String(r.results.linkConditions?.disconnects.count ?? 0),
                String(r.results.linkConditions?.discoveryFlaps ?? 0),
                csvEscape(r.results.linkConditions?.ssid ?? ""),
            ]
            rows.append(row.joined(separator: ","))
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
