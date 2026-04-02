import UIKit

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
                color: .secondaryLabel,
                width: contentWidth
            )

            let earliest = reports.map(\.date).min()!
            let latest = reports.map(\.date).max()!
            cursor.drawText(
                "\(reports.count) reports — \(dateFormatter.string(from: earliest)) to \(dateFormatter.string(from: latest))",
                font: .systemFont(ofSize: 10),
                color: .secondaryLabel,
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

            // Per-pair breakdown
            cursor.drawSectionHeader("Performance by Device Pair", width: contentWidth)
            drawPairTable(reports: reports, cursor: &cursor, width: contentWidth)
            cursor.y += 20

            // Per-chip summary
            cursor.drawSectionHeader("Performance by Chip", width: contentWidth)
            drawChipTable(reports: reports, cursor: &cursor, width: contentWidth)
            cursor.y += 20

            // Per-OS version
            cursor.drawSectionHeader("Performance by iPadOS Version", width: contentWidth)
            drawOSVersionTable(reports: reports, cursor: &cursor, width: contentWidth)
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

        let fileName = "iPadDx_Analytics_\(reports.count)_reports.pdf"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try? data.write(to: url)
        return url
    }

    // MARK: - Summary

    private static func drawSummaryTable(reports: [TestReport], cursor: inout Cursor, width: CGFloat) {
        let cols: [CGFloat] = [0.30, 0.175, 0.175, 0.175, 0.175]
        let headers = ["Metric", "Average", "Min", "Max", "Median"]

        cursor.drawTableRow(headers, columnWidths: cols, totalWidth: width, isHeader: true)

        let rows: [(String, [Double])] = [
            ("Avg Latency (ms)", reports.map(\.results.latencyBurst.avg)),
            ("P95 Latency (ms)", reports.map(\.results.latencyBurst.p95)),
            ("Throughput (MB/s)", reports.map { $0.results.sustainedThroughput.bytesPerSecond / 1_000_000 }),
            ("Avg Jitter (ms)", reports.map(\.results.jitterMeasurement.averageJitter)),
            ("Packet Loss (%)", reports.map(\.results.packetLossStress.lostPercent)),
            ("Load Degradation (%)", reports.map(\.results.latencyUnderLoad.degradationPercent)),
        ]

        for (label, values) in rows {
            let avg = values.reduce(0, +) / Double(values.count)
            let sorted = values.sorted()
            let mid = sorted.count / 2
            let med = sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
            cursor.drawTableRow(
                [label, f(avg), f(sorted.first ?? 0), f(sorted.last ?? 0), f(med)],
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
                    f(pairReports.map(\.results.latencyBurst.avg).reduce(0, +) / n),
                    f(pairReports.map(\.results.latencyBurst.p95).reduce(0, +) / n),
                    f(pairReports.map(\.results.sustainedThroughput.bytesPerSecond).reduce(0, +) / n / 1_000_000),
                    f(pairReports.map(\.results.jitterMeasurement.averageJitter).reduce(0, +) / n),
                    f(pairReports.map(\.results.packetLossStress.lostPercent).reduce(0, +) / n),
                    f(pairReports.map(\.results.latencyUnderLoad.degradationPercent).reduce(0, +) / n),
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
            let sAvg = asSender.isEmpty ? 0 : asSender.map(\.results.latencyBurst.avg)
                .reduce(0, +) / Double(asSender.count)
            let rAvg = asReceiver.isEmpty ? 0 : asReceiver.map(\.results.latencyBurst.avg)
                .reduce(0, +) / Double(asReceiver.count)
            let all = asSender + asReceiver
            let overall = all.isEmpty ? 0 : all.map(\.results.latencyBurst.avg).reduce(0, +) / Double(all.count)
            cursor.drawTableRow(
                [chip, "\(asSender.count)", f(sAvg), "\(asReceiver.count)", f(rAvg), f(overall)],
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
            // Worst thermal across responder reports
            let thermalOrder = ["Nominal", "Fair", "Serious", "Critical"]
            let worstThermal = devReports.compactMap(\.results.responderMetrics?.thermalStateDuringTest)
                .max(by: { (thermalOrder.firstIndex(of: $0) ?? 0) < (thermalOrder.firstIndex(of: $1) ?? 0) }) ?? "—"

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
            ["iPadOS", "#", "Lat (ms)", "P95 (ms)", "Thru (MB/s)", "Jitter (ms)", "Loss (%)", "Fail Rate (%)"],
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
                    f(vReports.map(\.results.latencyBurst.avg).reduce(0, +) / n),
                    f(vReports.map(\.results.latencyBurst.p95).reduce(0, +) / n),
                    f(vReports.map(\.results.sustainedThroughput.bytesPerSecond).reduce(0, +) / n / 1_000_000),
                    f(vReports.map(\.results.jitterMeasurement.averageJitter).reduce(0, +) / n),
                    f(vReports.map(\.results.packetLossStress.lostPercent).reduce(0, +) / n),
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
        let nativeAvgLat = nativeReports.isEmpty ? 0
            : nativeReports.map(\.results.latencyBurst.avg).reduce(0, +) / Double(nativeReports.count)

        for bridge in bridges {
            let br = reports.filter { ($0.bridgeTransport ?? "native") == bridge }
            guard !br.isEmpty else { continue }
            let n = Double(br.count)
            let avgLat = br.map(\.results.latencyBurst.avg).reduce(0, +) / n
            let delta = bridge == "native" ? "—" : String(format: "%+.1fms", avgLat - nativeAvgLat)
            cursor.drawTableRow(
                [
                    bridge, "\(br.count)",
                    f(avgLat),
                    f(br.map(\.results.latencyBurst.p95).reduce(0, +) / n),
                    f(br.map(\.results.sustainedThroughput.bytesPerSecond).reduce(0, +) / n / 1_000_000),
                    f(br.map(\.results.jitterMeasurement.averageJitter).reduce(0, +) / n),
                    f(br.map(\.results.packetLossStress.lostPercent).reduce(0, +) / n),
                    f(br.map(\.results.latencyUnderLoad.degradationPercent).reduce(0, +) / n),
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
                        f(br.map(\.results.latencyBurst.avg).reduce(0, +) / n),
                        f(br.map(\.results.latencyBurst.p95).reduce(0, +) / n),
                        f(br.map(\.results.sustainedThroughput.bytesPerSecond).reduce(0, +) / n / 1_000_000),
                        f(br.map(\.results.jitterMeasurement.averageJitter).reduce(0, +) / n),
                        gradeMode,
                    ],
                    columnWidths: cols, totalWidth: width, isHeader: false
                )
            }
        }
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
        color: UIColor = .label,
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
        UIColor.separator.setStroke()
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
        let color: UIColor = isHeader ? .label : .darkGray

        if isHeader {
            let bgRect = CGRect(x: x, y: y - 1, width: totalWidth, height: rowHeight + 2)
            UIColor.systemGray5.setFill()
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
        UIColor.systemGray4.setStroke()
        borderPath.lineWidth = 0.25
        borderPath.stroke()
        y += 1
    }
}
