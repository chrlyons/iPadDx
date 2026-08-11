import UIKit

/// Fixed light-appearance palette for PDF output.
/// A PDF must look identical regardless of the device's appearance, so nothing here
/// may be a trait-dependent system color (UIColor.label and friends resolve to
/// near-white in dark mode and would render as invisible text on the page).
private enum PDFPalette {
    static let page = UIColor.white
    static let title = UIColor(white: 0.05, alpha: 1)
    static let body = UIColor(white: 0.25, alpha: 1)
    static let secondary = UIColor(white: 0.45, alpha: 1)
    static let separator = UIColor(white: 0.75, alpha: 1)
    static let headerFill = UIColor(white: 0.91, alpha: 1)
    static let rowBorder = UIColor(white: 0.85, alpha: 1)
}

/// Renders a formatted PDF analytics report from test data
enum AnalyticsReportRenderer {
    // MARK: - Public

    static func renderPDF(reports: [TestReport]) -> URL? {
        guard !reports.isEmpty else { return nil }

        let pageWidth: CGFloat = 612 // US Letter
        let pageHeight: CGFloat = 792
        let margin: CGFloat = 50
        let contentWidth = pageWidth - margin * 2
        let pageRect = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)

        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)

        let data = renderer.pdfData { context in
            var cursor = Cursor(y: margin, pageRect: pageRect, margin: margin, context: context)
            cursor.beginPage()

            // Title
            cursor.drawText(
                "iPadDx Analytics Report",
                font: .systemFont(ofSize: 22, weight: .bold),
                width: contentWidth
            )
            cursor.y += 4

            let dateFormatter = DateFormatter()
            dateFormatter.dateStyle = .medium
            dateFormatter.timeStyle = .short
            cursor.drawText(
                "Generated \(dateFormatter.string(from: Date()))",
                font: .systemFont(ofSize: 10),
                color: PDFPalette.secondary,
                width: contentWidth
            )

            let earliest = reports.map(\.date).min()!
            let latest = reports.map(\.date).max()!
            cursor.drawText(
                "\(reports.count) reports — \(dateFormatter.string(from: earliest)) to \(dateFormatter.string(from: latest))",
                font: .systemFont(ofSize: 10),
                color: PDFPalette.secondary,
                width: contentWidth
            )
            cursor.y += 16

            // Summary table
            cursor.drawSectionHeader("Summary", width: contentWidth)
            drawSummaryTable(reports: reports, cursor: &cursor, width: contentWidth)
            cursor.y += 20

            // Grade distribution
            cursor.drawSectionHeader("Grade Distribution", width: contentWidth)
            drawGradeTable(reports: reports, cursor: &cursor, width: contentWidth)
            cursor.y += 20

            // Trends (a regression needs at least 3 reports)
            if reports.count >= 3 {
                cursor.drawSectionHeader("Trends", width: contentWidth)
                drawTrendTable(reports: reports, cursor: &cursor, width: contentWidth)
                cursor.y += 10
                drawPerPairTrendTable(reports: reports, cursor: &cursor, width: contentWidth)
                cursor.y += 20
            }

            // Per-pair breakdown
            cursor.drawSectionHeader("Performance by Device Pair", width: contentWidth)
            drawPairTable(reports: reports, cursor: &cursor, width: contentWidth)
            cursor.y += 20

            // Per-chip summary
            cursor.drawSectionHeader("Performance by Chip", width: contentWidth)
            drawChipTable(reports: reports, cursor: &cursor, width: contentWidth)
            cursor.y += 20

            // Per-OS version
            cursor.drawSectionHeader("Performance by OS Version", width: contentWidth)
            drawOSVersionTable(reports: reports, cursor: &cursor, width: contentWidth)
            cursor.y += 20

            // Per-OS pair (controller OS → responder OS)
            cursor.drawSectionHeader("Performance by OS Version Pair", width: contentWidth)
            drawOSPairTable(reports: reports, cursor: &cursor, width: contentWidth)
            cursor.y += 20

            // Responder vs Controller system metrics comparison
            let withResponder = reports.filter { $0.results.responderMetrics != nil }
            if !withResponder.isEmpty {
                cursor.drawSectionHeader(
                    "Controller vs Responder System Metrics (\(withResponder.count) reports)",
                    width: contentWidth
                )
                drawResponderComparisonTable(reports: withResponder, cursor: &cursor, width: contentWidth)
                cursor.y += 20
            }

            // Bridge Overhead Analysis (only if multiple bridges)
            let bridges = Array(Set(reports.map { $0.bridgeTransport ?? "native" })).sorted()
            if bridges.count > 1 {
                cursor.drawSectionHeader("Bridge Overhead Analysis", width: contentWidth)
                drawBridgeComparisonTable(reports: reports, bridges: bridges, cursor: &cursor, width: contentWidth)
                cursor.y += 10
                drawPerPairBridgeTable(reports: reports, bridges: bridges, cursor: &cursor, width: contentWidth)
                cursor.y += 20
            }

            // Failed tests
            let failed = reports.filter { $0.results.latencyBurst.sampleCount == 0 }
            if !failed.isEmpty {
                cursor.drawSectionHeader("Failed Tests (\(failed.count))", width: contentWidth)
                drawFailedTable(reports: failed, cursor: &cursor, width: contentWidth)
                cursor.y += 20
            }

            // All test data
            cursor.drawSectionHeader("All Test Data (\(reports.count) reports)", width: contentWidth)
            drawAllTestsTable(reports: reports, cursor: &cursor, width: contentWidth)
        }

        let fileName = "iPadDx_Analytics_\(reports.count)_reports_\(ReportExporter.fileStamp()).pdf"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try? data.write(to: url)
        return url
    }

    // MARK: - Summary

    /// Formats the mean of the reports that ACTUALLY MEASURED a metric, or "N/A".
    /// Cancelled and partial runs persist zero placeholders; averaging the raw field
    /// would drag every per-pair, per-chip and per-OS figure toward zero.
    private static func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func measuredAvg(
        _ reports: [TestReport],
        _ metric: (TestSuiteResults) -> Double?
    ) -> String {
        let values = reports.compactMap { metric($0.results) }
        guard !values.isEmpty else { return "N/A" }
        return f(values.reduce(0, +) / Double(values.count))
    }

    private static func drawSummaryTable(reports: [TestReport], cursor: inout Cursor, width: CGFloat) {
        let cols: [CGFloat] = [0.28, 0.15, 0.15, 0.15, 0.15, 0.12]
        let headers = ["Metric", "Average", "Min", "Max", "Median", "n"]

        cursor.drawTableRow(headers, columnWidths: cols, totalWidth: width, isHeader: true)

        // Only reports that actually measured a metric contribute to it. Disabled and
        // cancelled phases leave zero placeholders, and zero reads as a real value for
        // every one of these, so averaging raw fields would drag results toward zero.
        // `n` shows how many reports backed each row.
        let rows: [(String, [Double])] = [
            ("Avg Latency (ms)", reports.compactMap(\.results.measuredLatencyAvg)),
            ("P95 Latency (ms)", reports.compactMap(\.results.measuredLatencyP95)),
            ("Throughput (MB/s)", reports.compactMap { $0.results.measuredThroughput.map { $0 / 1_000_000 } }),
            ("Avg Jitter (ms)", reports.compactMap(\.results.measuredJitter)),
            ("Packet Loss (%)", reports.compactMap(\.results.measuredPacketLoss)),
            ("Load Degradation (%)", reports.compactMap(\.results.measuredLoadDegradation)),
        ]

        for (label, values) in rows {
            guard !values.isEmpty else {
                cursor.drawTableRow(
                    [label, "N/A", "N/A", "N/A", "N/A", "0"],
                    columnWidths: cols, totalWidth: width, isHeader: false
                )
                continue
            }
            let avg = values.reduce(0, +) / Double(values.count)
            let sorted = values.sorted()
            let mid = sorted.count / 2
            let med = sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
            cursor.drawTableRow(
                [label, f(avg), f(sorted.first ?? 0), f(sorted.last ?? 0), f(med), String(values.count)],
                columnWidths: cols, totalWidth: width, isHeader: false
            )
        }
    }

    // MARK: - Grades

    private static func drawGradeTable(reports: [TestReport], cursor: inout Cursor, width: CGFloat) {
        let cols: [CGFloat] = [0.30, 0.25, 0.25, 0.20]
        cursor.drawTableRow(["Grade", "Count", "Percent", ""], columnWidths: cols, totalWidth: width, isHeader: true)

        let grades = ["Excellent", "Good", "Fair", "Poor"]
        let total = Double(reports.count)
        for grade in grades {
            let count = reports.filter { $0.results.overallGrade == grade }.count
            if count > 0 {
                let pct = Double(count) / total * 100
                let bar = String(repeating: "\u{2588}", count: Int(pct / 5))
                cursor.drawTableRow(
                    [grade, "\(count)", String(format: "%.1f%%", pct), bar],
                    columnWidths: cols, totalWidth: width, isHeader: false
                )
            }
        }
    }

    // MARK: - Per-Pair

    private static func drawPairTable(reports: [TestReport], cursor: inout Cursor, width: CGFloat) {
        let cols: [CGFloat] = [0.22, 0.08, 0.12, 0.12, 0.12, 0.12, 0.11, 0.11]
        cursor.drawTableRow(
            ["Pair", "#", "Lat (ms)", "P95 (ms)", "Thru (MB/s)", "Jitter (ms)", "Loss (%)", "Degrad (%)"],
            columnWidths: cols, totalWidth: width, isHeader: true
        )

        let grouped = Dictionary(grouping: reports) {
            "\($0.localDevice.chipFamily) \u{2192} \($0.remoteDevice.chipFamily)"
        }

        for (pair, pairReports) in grouped.sorted(by: { $0.key < $1.key }) {
            let n = Double(pairReports.count)
            cursor.drawTableRow(
                [
                    pair,
                    "\(pairReports.count)",
                    measuredAvg(pairReports) { $0.measuredLatencyAvg },
                    measuredAvg(pairReports) { $0.measuredLatencyP95 },
                    measuredAvg(pairReports) { $0.measuredThroughput.map { $0 / 1_000_000 } },
                    measuredAvg(pairReports) { $0.measuredJitter },
                    measuredAvg(pairReports) { $0.measuredPacketLoss },
                    measuredAvg(pairReports) { $0.measuredLoadDegradation },
                ],
                columnWidths: cols, totalWidth: width, isHeader: false
            )
        }
    }

    // MARK: - Per-Chip

    private static func drawChipTable(reports: [TestReport], cursor: inout Cursor, width: CGFloat) {
        let cols: [CGFloat] = [0.15, 0.15, 0.20, 0.15, 0.20, 0.15]
        cursor.drawTableRow(
            ["Chip", "Sent #", "Sender Lat (ms)", "Recv #", "Receiver Lat (ms)", "Overall Lat"],
            columnWidths: cols, totalWidth: width, isHeader: true
        )

        let chips = Set(reports.flatMap { [$0.localDevice.chipFamily, $0.remoteDevice.chipFamily] }).sorted()
        for chip in chips {
            let asSender = reports.filter { $0.localDevice.chipFamily == chip }
            let asReceiver = reports.filter { $0.remoteDevice.chipFamily == chip }
            let all = asSender + asReceiver
            // Counts reflect reports that actually measured latency, so the "n" beside
            // each figure matches what produced it. This is the per-chip comparison the
            // whole tool exists for — a cancelled run's zero must never enter it.
            let sMeasured = asSender.filter(\.results.hasLatency).count
            let rMeasured = asReceiver.filter(\.results.hasLatency).count
            cursor.drawTableRow(
                [
                    chip,
                    "\(sMeasured)",
                    measuredAvg(asSender) { $0.measuredLatencyAvg },
                    "\(rMeasured)",
                    measuredAvg(asReceiver) { $0.measuredLatencyAvg },
                    measuredAvg(all) { $0.measuredLatencyAvg },
                ],
                columnWidths: cols, totalWidth: width, isHeader: false
            )
        }
    }

    // MARK: - Responder Comparison

    private static func drawResponderComparisonTable(reports: [TestReport], cursor: inout Cursor, width: CGFloat) {
        let cols: [CGFloat] = [0.18, 0.12, 0.12, 0.12, 0.12, 0.12, 0.12, 0.10]
        cursor.drawTableRow(
            [
                "Device (Resp)",
                "#",
                "Ctrl CPU %",
                "Resp CPU %",
                "Ctrl Mem MB",
                "Resp Mem MB",
                "Resp Thermal",
                "Resp Drain %",
            ],
            columnWidths: cols, totalWidth: width, isHeader: true
        )

        // Group by responder device
        let grouped = Dictionary(grouping: reports) { $0.remoteDevice.shortDescription }
        for (device, devReports) in grouped.sorted(by: { $0.key < $1.key }) {
            let n = Double(devReports.count)
            let ctrlCpu = devReports.map(\.results.systemMetrics.peakCpuUsage).reduce(0, +) / n
            let respCpu = devReports.compactMap(\.results.responderMetrics?.peakCpuUsage).reduce(0, +) / n
            let ctrlMem = devReports.map(\.results.systemMetrics.peakMemoryMB).reduce(0, +) / n
            let respMem = devReports.compactMap(\.results.responderMetrics?.peakMemoryMB).reduce(0, +) / n
            let respDrain = devReports.compactMap(\.results.responderMetrics?.batteryDrainPercent).reduce(0, +) / n
            // Worst thermal across responder reports. An unrecognized state ranks worst,
            // never best — we must not report an unknown state as "Nominal".
            let worstThermal = devReports.compactMap(\.results.responderMetrics?.thermalStateDuringTest)
                .max(by: { thermalRank($0) < thermalRank($1) }) ?? "—"

            cursor.drawTableRow(
                [
                    device,
                    "\(devReports.count)",
                    f(ctrlCpu),
                    f(respCpu),
                    f(ctrlMem),
                    f(respMem),
                    worstThermal,
                    f(respDrain),
                ],
                columnWidths: cols, totalWidth: width, isHeader: false
            )
        }
    }

    // MARK: - OS Version

    private static func drawOSVersionTable(reports: [TestReport], cursor: inout Cursor, width: CGFloat) {
        let cols: [CGFloat] = [0.18, 0.08, 0.12, 0.12, 0.12, 0.12, 0.12, 0.14]
        cursor.drawTableRow(
            ["OS", "#", "Lat (ms)", "P95 (ms)", "Thru (MB/s)", "Jitter (ms)", "Loss (%)", "Fail Rate (%)"],
            columnWidths: cols, totalWidth: width, isHeader: true
        )

        // Group by OS version (a report counts toward both local and remote OS)
        var map: [String: [TestReport]] = [:]
        for report in reports {
            map[report.localDevice.osVersion, default: []].append(report)
            if report.remoteDevice.osVersion != report.localDevice.osVersion {
                map[report.remoteDevice.osVersion, default: []].append(report)
            }
        }

        for (version, vReports) in map.sorted(by: { $0.key < $1.key }) {
            let n = Double(vReports.count)
            let failCount = vReports.filter { $0.results.overallGrade == "Poor" || $0.results.overallGrade == "Fair" }
                .count
            cursor.drawTableRow(
                [
                    version,
                    "\(vReports.count)",
                    measuredAvg(vReports) { $0.measuredLatencyAvg },
                    measuredAvg(vReports) { $0.measuredLatencyP95 },
                    measuredAvg(vReports) { $0.measuredThroughput.map { $0 / 1_000_000 } },
                    measuredAvg(vReports) { $0.measuredJitter },
                    measuredAvg(vReports) { $0.measuredPacketLoss },
                    f(Double(failCount) / n * 100),
                ],
                columnWidths: cols, totalWidth: width, isHeader: false
            )
        }
    }

    // MARK: - OS Version Pair

    private static func drawOSPairTable(reports: [TestReport], cursor: inout Cursor, width: CGFloat) {
        let cols: [CGFloat] = [0.25, 0.07, 0.11, 0.11, 0.11, 0.11, 0.11, 0.13]
        cursor.drawTableRow(
            ["OS Pair", "#", "Lat (ms)", "P95 (ms)", "Thru (MB/s)", "Jitter (ms)", "Loss (%)", "Fail Rate (%)"],
            columnWidths: cols, totalWidth: width, isHeader: true
        )

        let grouped = Dictionary(grouping: reports) {
            "\($0.localDevice.osVersion) \u{2192} \($0.remoteDevice.osVersion)"
        }

        for (pair, pairReports) in grouped.sorted(by: { $0.key < $1.key }) {
            let n = Double(pairReports.count)
            let failCount = pairReports
                .filter { $0.results.overallGrade == "Poor" || $0.results.overallGrade == "Fair" }.count
            cursor.drawTableRow(
                [
                    pair,
                    "\(pairReports.count)",
                    measuredAvg(pairReports) { $0.measuredLatencyAvg },
                    measuredAvg(pairReports) { $0.measuredLatencyP95 },
                    measuredAvg(pairReports) { $0.measuredThroughput.map { $0 / 1_000_000 } },
                    measuredAvg(pairReports) { $0.measuredJitter },
                    measuredAvg(pairReports) { $0.measuredPacketLoss },
                    f(Double(failCount) / n * 100),
                ],
                columnWidths: cols, totalWidth: width, isHeader: false
            )
        }
    }

    // MARK: - Failed

    private static func drawFailedTable(reports: [TestReport], cursor: inout Cursor, width: CGFloat) {
        let cols: [CGFloat] = [0.12, 0.15, 0.10, 0.15, 0.10, 0.38]
        cursor.drawTableRow(
            ["Date", "Sender", "Send OS", "Receiver", "Recv OS", "Errors"],
            columnWidths: cols,
            totalWidth: width,
            isHeader: true
        )

        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "MM/dd HH:mm"

        for report in reports {
            cursor.drawTableRow(
                [
                    dateFmt.string(from: report.date),
                    report.localDevice.shortDescription,
                    report.localDevice.osVersion,
                    report.remoteDevice.shortDescription,
                    report.remoteDevice.osVersion,
                    report.errors?.joined(separator: "; ") ?? "Unknown",
                ],
                columnWidths: cols, totalWidth: width, isHeader: false
            )
        }
    }

    // MARK: - All Tests

    private static func drawAllTestsTable(reports: [TestReport], cursor: inout Cursor, width: CGFloat) {
        let cols: [CGFloat] = [0.08, 0.11, 0.09, 0.11, 0.09, 0.06, 0.08, 0.08, 0.08, 0.08, 0.07, 0.07]
        cursor.drawTableRow(
            [
                "Date",
                "Sender",
                "Send OS",
                "Receiver",
                "Recv OS",
                "Grade",
                "Lat (ms)",
                "P95 (ms)",
                "Thru",
                "Jitter",
                "Loss %",
                "Degrad %",
            ],
            columnWidths: cols, totalWidth: width, isHeader: true
        )

        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "MM/dd HH:mm"

        for report in reports.sorted(by: { $0.date > $1.date }) {
            let r = report.results
            cursor.drawTableRow(
                [
                    dateFmt.string(from: report.date),
                    report.localDevice.shortDescription,
                    report.localDevice.osVersion,
                    report.remoteDevice.shortDescription,
                    report.remoteDevice.osVersion,
                    r.overallGrade,
                    f(r.latencyBurst.avg),
                    f(r.latencyBurst.p95),
                    f(r.sustainedThroughput.bytesPerSecond / 1_000_000),
                    f(r.jitterMeasurement.averageJitter),
                    f(r.packetLossStress.lostPercent),
                    f(r.latencyUnderLoad.degradationPercent),
                ],
                columnWidths: cols, totalWidth: width, isHeader: false
            )
        }
    }

    // MARK: - Bridge Comparison

    private static func drawBridgeComparisonTable(
        reports: [TestReport], bridges: [String], cursor: inout Cursor, width: CGFloat
    ) {
        let cols: [CGFloat] = [0.14, 0.07, 0.12, 0.12, 0.13, 0.12, 0.10, 0.10, 0.10]
        cursor.drawTableRow(
            [
                "Bridge",
                "#",
                "Lat (ms)",
                "P95 (ms)",
                "Thru (MB/s)",
                "Jitter (ms)",
                "Loss (%)",
                "Degrad (%)",
                "Δ vs Native",
            ],
            columnWidths: cols, totalWidth: width, isHeader: true
        )

        let nativeReports = reports.filter { ($0.bridgeTransport ?? "native") == "native" }
        // The native baseline every delta is measured against must itself come from
        // real measurements, or every bridge's overhead figure is wrong.
        let nativeAvgLat = mean(nativeReports.compactMap(\.results.measuredLatencyAvg))

        for bridge in bridges {
            let br = reports.filter { ($0.bridgeTransport ?? "native") == bridge }
            guard !br.isEmpty else { continue }
            let measuredLat = br.compactMap(\.results.measuredLatencyAvg)
            let avgLat = mean(measuredLat)
            let delta = if bridge == "native" {
                "—"
            } else if measuredLat.isEmpty || nativeAvgLat == nil {
                "N/A"
            } else {
                String(format: "%+.1fms", (avgLat ?? 0) - (nativeAvgLat ?? 0))
            }
            cursor.drawTableRow(
                [
                    bridge, "\(measuredLat.count)",
                    avgLat.map { f($0) } ?? "N/A",
                    measuredAvg(br) { $0.measuredLatencyP95 },
                    measuredAvg(br) { $0.measuredThroughput.map { $0 / 1_000_000 } },
                    measuredAvg(br) { $0.measuredJitter },
                    measuredAvg(br) { $0.measuredPacketLoss },
                    measuredAvg(br) { $0.measuredLoadDegradation },
                    delta,
                ],
                columnWidths: cols, totalWidth: width, isHeader: false
            )
        }
    }

    private static func drawPerPairBridgeTable(
        reports: [TestReport], bridges: [String], cursor: inout Cursor, width: CGFloat
    ) {
        cursor.drawText("Per-Pair Bridge Comparison", font: .systemFont(ofSize: 10, weight: .medium), width: width)

        let cols: [CGFloat] = [0.20, 0.12, 0.07, 0.12, 0.12, 0.12, 0.12, 0.13]
        cursor.drawTableRow(
            ["Pair", "Bridge", "#", "Lat (ms)", "P95 (ms)", "Thru (MB/s)", "Jitter (ms)", "Grade"],
            columnWidths: cols, totalWidth: width, isHeader: true
        )

        let grouped = Dictionary(grouping: reports) {
            "\($0.localDevice.chipFamily) \u{2192} \($0.remoteDevice.chipFamily)"
        }

        for (pair, pairReports) in grouped.sorted(by: { $0.key < $1.key }) {
            for bridge in bridges {
                let br = pairReports.filter { ($0.bridgeTransport ?? "native") == bridge }
                guard !br.isEmpty else { continue }
                let n = Double(br.count)
                let gradeMode = br.map(\.results.overallGrade)
                    .reduce(into: [:]) { $0[$1, default: 0] += 1 }
                    .max(by: { $0.value < $1.value })?.key ?? "—"
                cursor.drawTableRow(
                    [
                        pair, bridge, "\(br.count)",
                        measuredAvg(br) { $0.measuredLatencyAvg },
                        measuredAvg(br) { $0.measuredLatencyP95 },
                        measuredAvg(br) { $0.measuredThroughput.map { $0 / 1_000_000 } },
                        measuredAvg(br) { $0.measuredJitter },
                        gradeMode,
                    ],
                    columnWidths: cols, totalWidth: width, isHeader: false
                )
            }
        }
    }

    // MARK: - Trends

    /// The real observation window the regressions were fitted over.
    private static func trendPeriod(for reports: [TestReport]) -> String {
        TrendAnalyzer.describePeriod(dates: reports.map(\.date))
    }

    private static func trendMetrics() -> [(name: String, value: (TestReport) -> Double, lowerIsBetter: Bool)] {
        [
            (name: "Avg Latency", value: { $0.results.latencyBurst.avg }, lowerIsBetter: true),
            (name: "P95 Latency", value: { $0.results.latencyBurst.p95 }, lowerIsBetter: true),
            (
                name: "Throughput",
                value: { $0.results.sustainedThroughput.bytesPerSecond / 1_000_000 },
                lowerIsBetter: false
            ),
            (name: "Jitter", value: { $0.results.jitterMeasurement.averageJitter }, lowerIsBetter: true),
            (name: "Packet Loss", value: { $0.results.packetLossStress.lostPercent }, lowerIsBetter: true),
        ]
    }

    private static func drawTrendTable(reports: [TestReport], cursor: inout Cursor, width: CGFloat) {
        let cols: [CGFloat] = [0.24, 0.16, 0.16, 0.16, 0.28]
        cursor.drawTableRow(
            ["Metric", "Direction", "Change", "Confidence", "Period"],
            columnWidths: cols, totalWidth: width, isHeader: true
        )

        let period = trendPeriod(for: reports)
        for metric in trendMetrics() {
            let samples = reports.map { (date: $0.date, value: metric.value($0)) }
            guard let trend = TrendAnalyzer.analyzeTrend(
                samples: samples,
                metric: metric.name,
                lowerIsBetter: metric.lowerIsBetter,
                period: period
            ) else { continue }
            cursor.drawTableRow(
                [
                    trend.metric,
                    trend.isFlat ? "Flat" : trend.direction.rawValue.capitalized,
                    trend.isFlat ? "no variation" : String(format: "%+.1f%%", trend.changePercent),
                    trend.isFlat ? "—" : String(format: "%.0f%%", trend.confidence * 100),
                    trend.period,
                ],
                columnWidths: cols, totalWidth: width, isHeader: false
            )
        }
    }

    /// Per-pair trends — "which pairs are getting worse", degrading pairs first.
    private static func drawPerPairTrendTable(reports: [TestReport], cursor: inout Cursor, width: CGFloat) {
        cursor.drawText("Trends by Device Pair", font: .systemFont(ofSize: 10, weight: .medium), width: width)

        let cols: [CGFloat] = [0.24, 0.07, 0.15, 0.13, 0.15, 0.13, 0.13]
        cursor.drawTableRow(
            ["Pair", "#", "Latency", "Lat Δ", "Throughput", "Thru Δ", "Confidence"],
            columnWidths: cols, totalWidth: width, isHeader: true
        )

        let grouped = Dictionary(grouping: reports) {
            "\($0.localDevice.chipFamily) \u{2192} \($0.remoteDevice.chipFamily)"
        }

        struct PairTrend {
            let pair: String
            let count: Int
            let latency: TrendResult
            let throughput: TrendResult?
        }

        var rows: [PairTrend] = []
        for (pair, pairReports) in grouped {
            let period = trendPeriod(for: pairReports)
            guard let latency = TrendAnalyzer.analyzeTrend(
                samples: pairReports.map { (date: $0.date, value: $0.results.latencyBurst.avg) },
                metric: "Avg Latency", lowerIsBetter: true, period: period
            ) else { continue }
            let throughput = TrendAnalyzer.analyzeTrend(
                samples: pairReports
                    .map { (date: $0.date, value: $0.results.sustainedThroughput.bytesPerSecond / 1_000_000) },
                metric: "Throughput", lowerIsBetter: false, period: period
            )
            rows.append(PairTrend(pair: pair, count: pairReports.count, latency: latency, throughput: throughput))
        }

        guard !rows.isEmpty else {
            cursor.drawTableRow(
                ["No pair has the 3+ reports a trend needs.", "", "", "", "", "", ""],
                columnWidths: cols, totalWidth: width, isHeader: false
            )
            return
        }

        // Degrading first, then the largest movement.
        let sorted = rows.sorted { lhs, rhs in
            let lhsRank = trendRank(lhs.latency.direction)
            let rhsRank = trendRank(rhs.latency.direction)
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }
            return abs(lhs.latency.changePercent) > abs(rhs.latency.changePercent)
        }
        for row in sorted {
            cursor.drawTableRow(
                [
                    row.pair,
                    "\(row.count)",
                    row.latency.isFlat ? "Flat" : row.latency.direction.rawValue.capitalized,
                    row.latency.isFlat ? "—" : String(format: "%+.1f%%", row.latency.changePercent),
                    row.throughput.map { $0.isFlat ? "Flat" : $0.direction.rawValue.capitalized } ?? "—",
                    row.throughput.map { $0.isFlat ? "—" : String(format: "%+.1f%%", $0.changePercent) } ?? "—",
                    row.latency.isFlat ? "—" : String(format: "%.0f%%", row.latency.confidence * 100),
                ],
                columnWidths: cols, totalWidth: width, isHeader: false
            )
        }
    }

    /// Worsening pairs sort first.
    private static func trendRank(_ direction: TrendDirection) -> Int {
        switch direction {
        case .degrading: 0
        case .stable: 1
        case .improving: 2
        }
    }

    private static func thermalRank(_ state: String) -> Int {
        let order = ["Nominal", "Fair", "Serious", "Critical"]
        return order.firstIndex(of: state) ?? order.count
    }

    private static func f(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}

// MARK: - Cursor (page layout helper)

private struct Cursor {
    var y: CGFloat
    let pageRect: CGRect
    let margin: CGFloat
    let context: UIGraphicsPDFRendererContext

    var maxY: CGFloat {
        pageRect.height - margin
    }

    var x: CGFloat {
        margin
    }

    var contentWidth: CGFloat {
        pageRect.width - margin * 2
    }

    mutating func beginPage() {
        context.beginPage()
        // Explicit page fill — without it the page is transparent and dark viewers
        // (or dark-mode Quick Look) show light text on a dark ground.
        PDFPalette.page.setFill()
        UIBezierPath(rect: pageRect).fill()
        y = margin
    }

    mutating func ensureSpace(_ needed: CGFloat) {
        if y + needed > maxY {
            beginPage()
        }
    }

    mutating func drawText(
        _ text: String,
        font: UIFont = .systemFont(ofSize: 10),
        color: UIColor = PDFPalette.title,
        width: CGFloat
    ) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let rect = CGRect(x: x, y: y, width: width, height: 400)
        let boundingRect = (text as NSString).boundingRect(
            with: CGSize(width: width, height: 400),
            options: [.usesLineFragmentOrigin],
            attributes: attrs,
            context: nil
        )
        ensureSpace(boundingRect.height + 2)
        (text as NSString).draw(in: rect, withAttributes: attrs)
        y += boundingRect.height + 2
    }

    mutating func drawSectionHeader(_ text: String, width: CGFloat) {
        ensureSpace(30)
        // Divider line
        let path = UIBezierPath()
        path.move(to: CGPoint(x: x, y: y))
        path.addLine(to: CGPoint(x: x + width, y: y))
        PDFPalette.separator.setStroke()
        path.lineWidth = 0.5
        path.stroke()
        y += 8

        drawText(text, font: .systemFont(ofSize: 13, weight: .semibold), width: width)
        y += 4
    }

    mutating func drawTableRow(
        _ cells: [String],
        columnWidths: [CGFloat],
        totalWidth: CGFloat,
        isHeader: Bool
    ) {
        let rowHeight: CGFloat = 16
        ensureSpace(rowHeight + 2)

        let font: UIFont = isHeader ? .systemFont(ofSize: 8.5, weight: .semibold) : .systemFont(ofSize: 8.5)
        let color: UIColor = isHeader ? PDFPalette.title : PDFPalette.body

        if isHeader {
            let bgRect = CGRect(x: x, y: y - 1, width: totalWidth, height: rowHeight + 2)
            PDFPalette.headerFill.setFill()
            UIBezierPath(rect: bgRect).fill()
        }

        var cellX = x
        for (i, cell) in cells.enumerated() {
            let cellWidth = columnWidths[i] * totalWidth
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let textRect = CGRect(x: cellX + 3, y: y, width: cellWidth - 6, height: rowHeight)
            (cell as NSString).draw(
                in: textRect,
                withAttributes: attrs
            )
            cellX += cellWidth
        }

        y += rowHeight

        // Row border
        let borderPath = UIBezierPath()
        borderPath.move(to: CGPoint(x: x, y: y))
        borderPath.addLine(to: CGPoint(x: x + totalWidth, y: y))
        PDFPalette.rowBorder.setStroke()
        borderPath.lineWidth = 0.25
        borderPath.stroke()
        y += 1
    }
}
