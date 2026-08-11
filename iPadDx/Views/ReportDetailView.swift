import Charts
import SwiftUI

struct ReportDetailView: View {
    /// Loading and "could not be loaded" are different states — a stored report that
    /// fails to decode must not leave the view spinning forever.
    private enum LoadState {
        case loading
        case loaded(TestReport)
        case failed
    }

    let reportID: UUID
    var preloadedReport: TestReport?
    @Environment(ReportStore.self) private var store
    @State private var loadState: LoadState = .loading
    @State private var exportItem: ExportItem?
    @State private var isExporting = false
    @State private var exportError: String?
    @Environment(\.colorScheme) private var colorScheme

    /// Convenience init for direct report access (e.g., from conductor completed reports).
    init(report: TestReport) {
        reportID = report.id
        preloadedReport = report
        _loadState = State(initialValue: .loaded(report))
    }

    /// On-demand loading init (e.g., from report list).
    init(reportID: UUID) {
        self.reportID = reportID
        preloadedReport = nil
    }

    var body: some View {
        switch loadState {
        case .loading:
            ProgressView("Loading report…")
                .task { loadReport() }
        case let .loaded(report):
            reportContent(report)
        case .failed:
            loadFailedState
        }
    }

    private func loadReport() {
        if let preloadedReport {
            loadState = .loaded(preloadedReport)
            return
        }
        if let stored = store.loadFullReport(id: reportID) {
            loadState = .loaded(stored)
        } else {
            loadState = .failed
            AppLog(
                "Report \(reportID) could not be loaded — record missing or its payload failed to decode",
                level: .error,
                category: "Store"
            )
        }
    }

    private var loadFailedState: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text("This report could not be opened.")
                .font(.subheadline).fontWeight(.semibold)
            Text(store.initError
                ?? "Its stored record is missing or its saved data could not be decoded. Nothing was deleted.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try Again") {
                loadState = .loading
            }
            .buttonStyle(.bordered)
        }
        .padding(40)
        .navigationTitle("Report")
    }

    private func reportContent(_ report: TestReport) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                gradeHeader(report)
                devicePairCard(report)

                if hasDiagnostics(report) {
                    diagnosticsCard(report)
                }

                if let dns = report.results.dnsResolution {
                    dnsResolutionCard(dns)
                }

                if !report.results.latencyBurst.samples.isEmpty {
                    latencyChartCard(report)
                }

                if report.results.latencyBurst.histogram != nil {
                    latencyHistogramCard(report)
                }

                latencyCard(report)
                throughputCard(report)
                jitterCard(report)
                packetLossCard(report)
                latencyUnderLoadCard(report)
                systemMetricsCard(report)
            }
            .padding()
        }
        .navigationTitle("\(report.localDevice.chipFamily) vs \(report.remoteDevice.chipFamily)")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    ForEach(ExportFormat.allCases) { format in
                        Button {
                            exportSingle(report, format: format)
                        } label: {
                            Label(format.rawValue, systemImage: format.icon)
                        }
                    }

                    Divider()

                    Button {
                        exportDetailCSV(report)
                    } label: {
                        Label("Full Detail CSV", systemImage: "tablecells.badge.ellipsis")
                    }

                    Button {
                        UIPasteboard.general.string = ReportExporter.clipboardSummary(report: report)
                    } label: {
                        Label("Copy Summary", systemImage: "doc.on.clipboard")
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .sheet(item: $exportItem) { item in
            ShareSheet(activityItems: item.urls)
        }
        .overlay {
            if isExporting {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Preparing export…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(20)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .alert(
            "Export failed",
            isPresented: Binding(get: { exportError != nil }, set: {
                if !$0 {
                    exportError = nil
                }
            })
        ) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    // MARK: - Export

    private func exportSingle(_ report: TestReport, format: ExportFormat) {
        runExport { try [ReportExporter.exportSingle(report: report, format: format)] }
    }

    /// The store's key/value CSV — every measured field for this one report.
    private func exportDetailCSV(_ report: TestReport) {
        let reportStore = store
        runExport {
            guard let url = reportStore.exportCSV(for: report) else { throw CocoaError(.fileWriteUnknown) }
            return [url]
        }
    }

    /// PDF rendering and CSV assembly happen off the main actor so the UI stays live.
    private func runExport(_ build: @escaping @Sendable () throws -> [URL]) {
        isExporting = true
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<[URL], Error> in
                do {
                    return try .success(build())
                } catch {
                    return .failure(error)
                }
            }.value
            isExporting = false
            switch result {
            case let .success(urls) where !urls.isEmpty:
                exportItem = ExportItem(urls: urls)
            case .success:
                exportError = "No files were produced."
            case let .failure(error):
                AppLog("Export failed: \(error)", level: .error, category: "Store")
                exportError = error.localizedDescription
            }
        }
    }

    private func gradeHeader(_ report: TestReport) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text("Overall Grade")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(report.results.overallGrade)
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundStyle(gradeColor(report.results.overallGrade))
                if let bridge = report.bridgeTransport, bridge != "native" {
                    Text(bridge)
                        .font(.caption).fontWeight(.medium)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.orange.opacity(0.12), in: Capsule())
                }
                if let link = report.results.linkConditions {
                    Text(link.summary)
                        .font(.caption2).fontWeight(.medium)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(
                            (link.usedPeerToPeer ? Color.teal : Color.gray).opacity(0.15),
                            in: Capsule()
                        )
                    if link.pathChanges > 0 || !link.disconnects.isEmpty {
                        Text(
                            "\(link.pathChanges) link change(s), \(link.disconnects.count) drop(s)"
                        )
                        .font(.caption2)
                        .foregroundStyle(.red)
                    }
                }
            }
            Spacer()
            VStack(alignment: .trailing) {
                Text(report.date, style: .date)
                    .font(.caption)
                Text(report.date, style: .time)
                    .font(.caption)
                Text(String(format: "Duration: %.1fs", report.durationSeconds))
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func devicePairCard(_ report: TestReport) -> some View {
        HStack {
            deviceColumn("Sender (Controller)", report.localDevice)
            Spacer()
            VStack(spacing: 4) {
                Image(systemName: "arrow.right")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("test direction")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            deviceColumn("Receiver (Responder)", report.remoteDevice)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func latencyChartCard(_ report: TestReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "chart.xyaxis.line")
                    .foregroundStyle(.blue)
                Text("Latency Samples")
                    .font(.headline)
                Spacer()
            }

            Chart {
                ForEach(Array(report.results.latencyBurst.samples.enumerated()), id: \.offset) { i, value in
                    LineMark(x: .value("Sample", i), y: .value("ms", value))
                        .foregroundStyle(.blue.gradient)
                        .interpolationMethod(.catmullRom)
                    AreaMark(x: .value("Sample", i), y: .value("ms", value))
                        .foregroundStyle(.blue.opacity(0.1).gradient)
                        .interpolationMethod(.catmullRom)
                }

                // Thermal transition markers
                if let transitions = report.results.systemMetrics.thermalTransitions {
                    let sampleCount = report.results.latencyBurst.samples.count
                    let duration = report.durationSeconds
                    ForEach(transitions) { transition in
                        let elapsed = transition.timestamp.timeIntervalSince(report.date)
                        let sampleIndex = Int((elapsed / duration) * Double(sampleCount))
                        if sampleIndex >= 0, sampleIndex < sampleCount {
                            RuleMark(x: .value("Sample", sampleIndex))
                                .foregroundStyle(Color.thermalColor(transition.to).opacity(0.6))
                                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                                .annotation(position: .top, spacing: 2) {
                                    Text(transition.to)
                                        .font(.system(size: 8))
                                        .foregroundStyle(Color.thermalColor(transition.to))
                                }
                        }
                    }
                }
            }
            .chartYAxisLabel("ms")
            .chartXAxis(.hidden)
            .frame(height: 150)

            // Thermal transition legend
            if let transitions = report.results.systemMetrics.thermalTransitions, !transitions.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "thermometer.variable")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    ForEach(transitions) { t in
                        HStack(spacing: 2) {
                            Text("\(t.from)")
                                .font(.caption2)
                                .foregroundStyle(Color.thermalColor(t.from))
                            Image(systemName: "arrow.right")
                                .font(.system(size: 7))
                                .foregroundStyle(.secondary)
                            Text("\(t.to)")
                                .font(.caption2)
                                .foregroundStyle(Color.thermalColor(t.to))
                        }
                    }
                    Spacer()
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Latency Histogram

    private func latencyHistogramCard(_ report: TestReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "chart.bar.fill")
                    .foregroundStyle(.blue)
                Text("Latency Distribution")
                    .font(.headline)
                Spacer()
            }

            if let histogram = report.results.latencyBurst.histogram, !histogram.isEmpty {
                // Numeric range bars, not category labels: buckets are often narrower
                // than 1ms, and rounding their start to a whole number collapsed
                // several distinct buckets onto the same label.
                let decimals = histogramDecimals(histogram)
                Chart(histogram) { bucket in
                    BarMark(
                        xStart: .value("From", bucket.rangeStart),
                        xEnd: .value("To", bucket.rangeEnd),
                        y: .value("Count", bucket.count)
                    )
                    .foregroundStyle(
                        bucket.rangeEnd < 10 ? Color.green :
                            bucket.rangeEnd < 30 ? Color.blue :
                            bucket.rangeEnd < 100 ? Color.orange : Color.red
                    )
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 6)) { value in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel {
                            if let ms = value.as(Double.self) {
                                Text(String(format: "%.\(decimals)f", ms))
                            }
                        }
                    }
                }
                .chartXAxisLabel("ms")
                .chartYAxisLabel("Count")
                .frame(height: 150)

                let range = String(
                    format: "%.\(decimals)f\u{2013}%.\(decimals)fms",
                    histogram.first?.rangeStart ?? 0,
                    histogram.last?.rangeEnd ?? 0
                )
                Text("\(histogram.count) buckets across \(range)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            // Extended percentiles
            let l = report.results.latencyBurst
            if l.p5 != nil {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 8) {
                    if let p5 = l.p5 {
                        statItem("P5", String(format: "%.1fms", p5), .green)
                    }
                    if let p25 = l.p25 {
                        statItem("P25", String(format: "%.1fms", p25), .teal)
                    }
                    if let p75 = l.p75 {
                        statItem("P75", String(format: "%.1fms", p75), .orange)
                    }
                    if let p99 = l.p99 {
                        statItem("P99", String(format: "%.1fms", p99), .red)
                    }
                }
            }

            if let anomalyCount = l.anomalyCount, anomalyCount > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                    Text("\(anomalyCount) anomalies detected during burst")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func latencyCard(_ report: TestReport) -> some View {
        resultCard("Latency Burst", icon: "bolt.fill", color: .blue) {
            let l = report.results.latencyBurst
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 8) {
                statItem("Min", String(format: "%.1fms", l.min), .green)
                statItem("Max", String(format: "%.1fms", l.max), .red)
                statItem("Avg", String(format: "%.1fms", l.avg), .blue)
                statItem("Median", String(format: "%.1fms", l.median), .indigo)
                statItem("P95", String(format: "%.1fms", l.p95), .orange)
            }
        }
    }

    private func throughputCard(_ report: TestReport) -> some View {
        resultCard("Throughput", icon: "arrow.up.arrow.down.circle.fill", color: .purple) {
            let t = report.results.sustainedThroughput
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 8) {
                statItem("Speed", t.formattedSpeed, .purple)
                statItem("Data", formatBytes(t.totalBytes), .cyan)
                statItem("Duration", String(format: "%.1fs", t.durationSeconds), .gray)
            }
        }
    }

    private func jitterCard(_ report: TestReport) -> some View {
        resultCard("Jitter", icon: "waveform.path", color: .orange) {
            let j = report.results.jitterMeasurement
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 8) {
                statItem("Average", String(format: "%.2fms", j.averageJitter), .orange)
                statItem("Max", String(format: "%.2fms", j.maxJitter), .red)
                statItem("Samples", "\(j.sampleCount)", .gray)
            }
        }
    }

    private func packetLossCard(_ report: TestReport) -> some View {
        resultCard("Packet Loss", icon: "exclamationmark.triangle.fill", color: .red) {
            let p = report.results.packetLossStress
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 8) {
                statItem("Sent", "\(p.sent)", .blue)
                statItem("Received", "\(p.received)", .green)
                statItem("Loss", String(format: "%.1f%%", p.lostPercent), p.lostPercent < 1 ? .green : .red)
                statItem("Duration", String(format: "%.1fs", p.durationSeconds), .gray)
            }
        }
    }

    private func latencyUnderLoadCard(_ report: TestReport) -> some View {
        resultCard("Latency Under Load", icon: "flame.fill", color: .orange) {
            let l = report.results.latencyUnderLoad
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 8) {
                statItem("Baseline", String(format: "%.1fms", l.baselineAvg), .blue)
                statItem("Under Load", String(format: "%.1fms", l.underLoadAvg), .orange)
                statItem(
                    "Impact",
                    l.formattedDegradation,
                    l.degradationPercent <= 0 ? .green : l.degradationPercent < 50 ? .orange : .red
                )
                statItem("Samples", "\(l.sampleCount)", .gray)
            }
        }
    }

    private func systemMetricsCard(_ report: TestReport) -> some View {
        resultCard("System Metrics", icon: "cpu", color: .indigo) {
            let s = report.results.systemMetrics
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 8) {
                statItem(
                    "Battery Drain",
                    String(format: "%.2f%%", s.batteryDrainPercent),
                    s.batteryDrainPercent < 1 ? .green : .orange
                )
                statItem(
                    "Peak CPU",
                    String(format: "%.0f%%", s.peakCpuUsage),
                    s.peakCpuUsage < 50 ? .green : .orange
                )
                statItem("Peak Mem", String(format: "%.0fMB", s.peakMemoryMB), .indigo)
                statItem(
                    "Thermal",
                    s.thermalStateDuringTest,
                    s.thermalStateDuringTest == "Nominal" ? .green : .orange
                )
            }
        }
    }

    /// Decimal places that keep neighbouring bucket edges distinguishable.
    private func histogramDecimals(_ histogram: [HistogramBucket]) -> Int {
        let width = histogram.map { $0.rangeEnd - $0.rangeStart }.min() ?? 0
        if width >= 10 {
            return 0
        }
        if width >= 1 {
            return 1
        }
        if width >= 0.1 {
            return 2
        }
        return 3
    }

    // MARK: - Errors & Skipped Phases

    private func hasDiagnostics(_ report: TestReport) -> Bool {
        !(report.errors ?? []).isEmpty || !(report.skippedPhases ?? []).isEmpty
    }

    private func diagnosticsCard(_ report: TestReport) -> some View {
        let errors = report.errors ?? []
        let skipped = report.skippedPhases ?? []

        return VStack(alignment: .leading, spacing: 12) {
            if !errors.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        Text("Errors (\(errors.count))").font(.headline)
                        Spacer()
                    }
                    ForEach(Array(errors.enumerated()), id: \.offset) { index, message in
                        HStack(alignment: .top, spacing: 6) {
                            Text("\(index + 1).")
                                .font(.caption).fontWeight(.semibold)
                                .foregroundStyle(.red)
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(8)
                        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }

            if !skipped.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "forward.end.alt.fill").foregroundStyle(.orange)
                        Text("Skipped Phases (\(skipped.count))").font(.headline)
                        Spacer()
                    }
                    Text("These phases did not run, so this report contains no measurements for them.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 120), spacing: 6)],
                        alignment: .leading,
                        spacing: 6
                    ) {
                        ForEach(Array(skipped.enumerated()), id: \.offset) { _, phase in
                            Text(phase)
                                .font(.caption)
                                .lineLimit(1)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(.orange.opacity(0.12), in: Capsule())
                        }
                    }
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - DNS Resolution

    private func dnsResolutionCard(_ dns: DNSResolutionResult) -> some View {
        let timeColor: Color = dns.resolutionTimeMs < 100 ? .green :
            dns.resolutionTimeMs < 300 ? .blue :
            dns.resolutionTimeMs < 500 ? .orange : .red

        return resultCard("DNS Resolution", icon: "magnifyingglass.circle.fill", color: .cyan) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 8) {
                statItem("Time", String(format: "%.0fms", dns.resolutionTimeMs), timeColor)
                statItem("Status", dns.resolved ? "Resolved" : "Failed", dns.resolved ? .green : .red)
                statItem("Service", dns.serviceName, .gray)
            }

            if dns.resolutionTimeMs > 300 {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Text("Slow resolution — mDNS may be congested or the peer took time to respond")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Helpers

    private func deviceColumn(_ label: String, _ info: DeviceInfo) -> some View {
        VStack(spacing: 4) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(info.name).font(.subheadline).fontWeight(.medium)
            Text(info.displayModel).font(.caption).foregroundStyle(.secondary)
            if !info.modelNumber.isEmpty {
                Text(info.modelNumber).font(.caption2).foregroundStyle(.tertiary)
            }
            Text(info.osVersion).font(.caption2).foregroundStyle(.tertiary)
            Text(info.chipFamily)
                .font(.caption).fontWeight(.bold)
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(.blue.opacity(0.1), in: Capsule())
        }
    }

    private func resultCard(
        _ title: String,
        icon: String,
        color: Color,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: icon).foregroundStyle(color)
                Text(title).font(.headline)
                Spacer()
            }
            content()
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func statItem(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.subheadline).fontWeight(.semibold).foregroundStyle(color)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(6)
        .frame(maxWidth: .infinity)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func gradeColor(_ grade: String) -> Color {
        Color.gradeColor(grade, scheme: colorScheme)
    }

    private func formatBytes(_ bytes: Int) -> String {
        if bytes >= 1_000_000 {
            return String(format: "%.1f MB", Double(bytes) / 1_000_000)
        }
        if bytes >= 1000 {
            return String(format: "%.1f KB", Double(bytes) / 1000)
        }
        return "\(bytes) B"
    }
}
