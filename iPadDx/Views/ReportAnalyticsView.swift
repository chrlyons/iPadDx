import Charts
import SwiftUI

private enum AnalyticsMetric: String, CaseIterable, Identifiable {
    case latencyAvg = "Avg Latency"
    case latencyP95 = "P95 Latency"
    case throughput = "Throughput"
    case jitterAvg = "Avg Jitter"
    case packetLoss = "Packet Loss"
    case loadDegradation = "Load Degradation"

    var id: String {
        rawValue
    }

    var unit: String {
        switch self {
        case .latencyAvg, .latencyP95, .jitterAvg: "ms"
        case .throughput: "MB/s"
        case .packetLoss, .loadDegradation: "%"
        }
    }

    var lowerIsBetter: Bool {
        self != .throughput
    }
}

/// The artefacts the analytics screen can export.
private enum AnalyticsExportKind {
    case pdf
    case summaryCSV
    case analyticsCSV
}

private enum DateRangePreset: String, CaseIterable, Identifiable {
    case all = "All Time"
    case week = "7 Days"
    case month = "30 Days"
    case quarter = "90 Days"
    case custom = "Custom"

    var id: String {
        rawValue
    }

    var icon: String {
        switch self {
        case .all: "infinity"
        case .week: "7.square"
        case .month: "30.square"
        case .quarter: "90.square"
        case .custom: "calendar"
        }
    }
}

/// Mean over values that were actually measured.
///
/// Skipped and cancelled phases persist zeros, and zero is indistinguishable from a
/// real latency/jitter/loss/throughput reading, so a raw average silently drags every
/// figure toward zero. Returns nil when nothing measured the metric.
func measuredMean(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    return values.reduce(0, +) / Double(values.count)
}

struct ReportAnalyticsView: View {
    @Environment(ReportStore.self) private var store
    @State private var selectedPair: String = "All"
    @State private var selectedOS: String = "All"
    @State private var selectedBridge: String = "All"
    @State private var datePreset: DateRangePreset = .all
    @State private var customStart: Date = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
    @State private var customEnd: Date = .init()
    @State private var selectedMetric: AnalyticsMetric = .latencyAvg
    @State private var exportURLs: [URL]?
    @State private var isExporting = false
    @State private var exportError: String?

    private var effectiveDateRange: (start: Date?, end: Date?) {
        switch datePreset {
        case .all: (nil, nil)
        case .week: (Calendar.current.date(byAdding: .day, value: -7, to: Date()), nil)
        case .month: (Calendar.current.date(byAdding: .day, value: -30, to: Date()), nil)
        case .quarter: (Calendar.current.date(byAdding: .day, value: -90, to: Date()), nil)
        case .custom: (
                Calendar.current.startOfDay(for: customStart),
                Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: customEnd))
            )
        }
    }

    private var uniquePairs: [String] {
        let pairs = store.summaries.map { "\($0.localChip) vs \($0.remoteChip)" }
        return Array(Set(pairs)).sorted()
    }

    private var uniqueOSVersions: [String] {
        let versions = Set(store.summaries.flatMap { [$0.localOS, $0.remoteOS] })
        return versions.sorted()
    }

    private var filteredSummaries: [ReportSummary] {
        let range = effectiveDateRange
        return store.summaries.filter { summary in
            let pair = "\(summary.localChip) vs \(summary.remoteChip)"
            let matchesPair = selectedPair == "All" || pair == selectedPair
            let afterStart = range.start.map { summary.date >= $0 } ?? true
            let beforeEnd = range.end.map { summary.date < $0 } ?? true
            let matchesOS = selectedOS == "All"
                || summary.localOS == selectedOS
                || summary.remoteOS == selectedOS
            let matchesBridge = selectedBridge == "All" || summary.bridgeTransport == selectedBridge
            return matchesPair && afterStart && beforeEnd && matchesOS && matchesBridge
        }
        .sorted { $0.date < $1.date }
    }

    private var pairAverages: [PairAggregate] {
        let grouped = Dictionary(grouping: filteredSummaries) {
            "\($0.localChip) vs \($0.remoteChip)|\($0.bridgeTransport)"
        }
        let hasBridges = Set(filteredSummaries.map(\.bridgeTransport)).count > 1
        return grouped.map { _, summaries in
            let pair = "\(summaries[0].localChip) vs \(summaries[0].remoteChip)"
            let bridge = summaries[0].bridgeTransport
            let label = hasBridges ? "\(pair) [\(bridge)]" : pair
            let avg = summaries.map { metricValue(for: $0) }.reduce(0, +) / Double(summaries.count)
            return PairAggregate(pair: label, average: avg, count: summaries.count, bridge: bridge)
        }
        .sorted { $0.pair < $1.pair }
    }

    private var osPairAverages: [OSPairAggregate] {
        let grouped: [String: [ReportSummary]] = Dictionary(grouping: filteredSummaries) {
            "\($0.localOS) \u{2192} \($0.remoteOS)"
        }
        return grouped.map { entry -> OSPairAggregate in
            let summaries = entry.value
            let avg = summaries.map { metricValue(for: $0) }.reduce(0, +) / Double(summaries.count)
            return OSPairAggregate(pair: entry.key, average: avg, count: summaries.count)
        }
        .sorted { $0.pair < $1.pair }
    }

    private var gradeDistribution: [(grade: String, count: Int, color: Color)] {
        let grades = ["Excellent", "Good", "Fair", "Poor"]
        let colors: [Color] = [.green, .blue, .orange, .red]
        let summaries = filteredSummaries
        var result: [(grade: String, count: Int, color: Color)] = []
        for i in 0 ..< grades.count {
            let gradeCount = summaries.filter { $0.overallGrade == grades[i] }.count
            if gradeCount > 0 {
                result.append((grade: grades[i], count: gradeCount, color: colors[i]))
            }
        }
        return result
    }

    var body: some View {
        ScrollView {
            if store.summaries.isEmpty {
                emptyState
            } else {
                VStack(spacing: 16) {
                    filterBar
                    summaryCards
                    trendBadgesSection
                    pairTrendsSection
                    trendChart
                    pairComparisonChart
                    osPairComparisonChart

                    // Bridge comparison (only when multiple bridges exist)
                    if store.availableBridgeTransports().count > 1 {
                        bridgeComparisonChart
                    }

                    osVersionChart
                    gradeChart
                }
                .padding()
            }
        }
        .navigationTitle("Analytics")
        .toolbar {
            if !store.summaries.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            exportAnalytics(kinds: [.pdf, .summaryCSV])
                        } label: {
                            Label("PDF + Summary CSV", systemImage: "doc.on.doc")
                        }
                        Button {
                            exportAnalytics(kinds: [.pdf])
                        } label: {
                            Label("Analytics PDF", systemImage: "doc.richtext")
                        }
                        Button {
                            exportAnalytics(kinds: [.analyticsCSV])
                        } label: {
                            Label("Analytics CSV (raw data)", systemImage: "chart.bar.doc.horizontal")
                        }
                        Button {
                            exportAnalytics(kinds: [.summaryCSV])
                        } label: {
                            Label("Summary CSV (one row per report)", systemImage: "tablecells")
                        }
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .disabled(isExporting)
                }
            }
        }
        .overlay {
            if isExporting {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Building analytics export…")
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
        .sheet(isPresented: Binding(
            get: { exportURLs != nil },
            set: {
                if !$0 {
                    exportURLs = nil
                }
            }
        )) {
            if let urls = exportURLs {
                ShareSheet(activityItems: urls)
                    .presentationDetents([.medium, .large])
            }
        }
    }

    /// Loads the matching reports (SwiftData stays on the main actor) and then builds
    /// the files off the main actor — rendering a PDF for a large store takes seconds.
    private func exportAnalytics(kinds: [AnalyticsExportKind]) {
        let reports = store.loadFullReports(ids: Set(filteredSummaries.map(\.id)))
        guard !reports.isEmpty else {
            exportError = "There are no reports matching the current filters to export."
            return
        }
        let reportStore = store
        isExporting = true
        Task {
            let urls = await Task.detached(priority: .userInitiated) { () -> [URL] in
                kinds.compactMap { kind -> URL? in
                    switch kind {
                    case .pdf: return AnalyticsReportRenderer.renderPDF(reports: reports)
                    case .summaryCSV: return reportStore.exportSummaryCSV(for: reports)
                    case .analyticsCSV: return reportStore.exportAnalyticsCSV(for: reports)
                    }
                }
            }.value
            isExporting = false
            if urls.isEmpty {
                exportError = "The export files could not be written."
            } else {
                exportURLs = urls
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 50))
                .foregroundStyle(.secondary)
            Text("No reports to analyze.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Run test suites and save reports to see analytics here.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Picker("Pair", selection: $selectedPair) {
                    Text("All Pairs").tag("All")
                    ForEach(uniquePairs, id: \.self) { pair in
                        Text(pair).tag(pair)
                    }
                }
                .pickerStyle(.menu)

                Picker("OS", selection: $selectedOS) {
                    Text("All OS").tag("All")
                    ForEach(uniqueOSVersions, id: \.self) { version in
                        Text(version).tag(version)
                    }
                }
                .pickerStyle(.menu)

                if store.availableBridgeTransports().count > 1 {
                    Picker("Bridge", selection: $selectedBridge) {
                        Text("All Bridges").tag("All")
                        ForEach(store.availableBridgeTransports(), id: \.self) { bridge in
                            Text(bridge).tag(bridge)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Picker("Metric", selection: $selectedMetric) {
                    ForEach(AnalyticsMetric.allCases) { metric in
                        Text(metric.rawValue).tag(metric)
                    }
                }
                .pickerStyle(.menu)
            }

            HStack(spacing: 8) {
                ForEach(DateRangePreset.allCases) { preset in
                    Button {
                        datePreset = preset
                    } label: {
                        Text(preset.rawValue)
                            .font(.caption)
                            .fontWeight(datePreset == preset ? .semibold : .regular)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                datePreset == preset
                                    ? AnyShapeStyle(.blue.opacity(0.15))
                                    : AnyShapeStyle(.quaternary),
                                in: Capsule()
                            )
                            .foregroundStyle(datePreset == preset ? .blue : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            if datePreset == .custom {
                HStack(spacing: 12) {
                    DatePicker("From", selection: $customStart, in: ...customEnd, displayedComponents: .date)
                        .labelsHidden()
                    Image(systemName: "arrow.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    DatePicker("To", selection: $customEnd, in: customStart..., displayedComponents: .date)
                        .labelsHidden()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: datePreset)
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Summary Cards

    private var summaryCards: some View {
        let items = filteredSummaries
        let count = items.count

        return LazyVGrid(columns: [
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12),
        ], spacing: 12) {
            summaryItem("Reports", "\(count)", .blue)
            summaryItem(
                "Avg Latency",
                measuredMean(items.compactMap(\.measuredLatencyAvg))
                    .map { String(format: "%.1fms", $0) } ?? "-",
                .blue
            )
            summaryItem(
                "Avg Throughput",
                measuredMean(items.compactMap(\.measuredThroughput))
                    .map { String(format: "%.1f MB/s", $0 / 1_000_000) } ?? "-",
                .purple
            )
            summaryItem(
                "Avg Jitter",
                measuredMean(items.compactMap(\.measuredJitter))
                    .map { String(format: "%.1fms", $0) } ?? "-",
                .orange
            )
            summaryItem(
                "Avg Loss",
                measuredMean(items.compactMap(\.measuredPacketLoss))
                    .map { String(format: "%.1f%%", $0) } ?? "-",
                .red
            )
            summaryItem("OS Versions", "\(uniqueOSVersions.count)", .indigo)
        }
    }

    // MARK: - Trend Badges

    private var trendBadgesSection: some View {
        let summaries = filteredSummaries
        let trends = computeTrends(from: summaries)

        return Group {
            if !trends.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "chart.line.uptrend.xyaxis")
                            .foregroundStyle(.blue)
                        Text("Trend Analysis")
                            .font(.headline)
                        Spacer()
                        Text(summaries.count >= 3 ? "Based on \(summaries.count) reports" : "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    LazyVGrid(
                        columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                        spacing: 8
                    ) {
                        ForEach(trends) { trend in
                            VStack(spacing: 4) {
                                HStack(spacing: 4) {
                                    Image(systemName: trend.direction.icon)
                                        .font(.caption)
                                        .foregroundStyle(Color.trendColor(trend.direction))
                                    Text(String(format: "%+.1f%%", trend.changePercent))
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(Color.trendColor(trend.direction))
                                }
                                Text(trend.metric)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                // Confidence bar
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        RoundedRectangle(cornerRadius: 2)
                                            .fill(Color.gray.opacity(0.15))
                                        RoundedRectangle(cornerRadius: 2)
                                            .fill(Color.trendColor(trend.direction).opacity(0.4))
                                            .frame(width: geo.size.width * trend.confidence)
                                    }
                                }
                                .frame(height: 3)
                                Text(trend.isFlat
                                    ? "no variation in samples"
                                    : String(format: "%.0f%% confidence", trend.confidence * 100))
                                    .font(.system(size: 8))
                                    .foregroundStyle(.tertiary)
                                Text(trend.period)
                                    .font(.system(size: 8))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                            .padding(8)
                            .background(
                                Color.trendColor(trend.direction).opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                        }
                    }
                }
                .padding()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func computeTrends(from summaries: [ReportSummary]) -> [TrendResult] {
        guard summaries.count >= 3 else { return [] }

        let metrics: [(name: String, keyPath: KeyPath<ReportSummary, Double>, lowerIsBetter: Bool)] = [
            ("Latency Avg", \.latencyAvg, true),
            ("Latency P95", \.latencyP95, true),
            ("Throughput", \.throughputBps, false),
            ("Jitter", \.jitterAvg, true),
            ("Packet Loss", \.packetLossPercent, true),
        ]

        // Real window the regression was fitted over — shown on each badge.
        let period = TrendAnalyzer.describePeriod(dates: summaries.map(\.date))

        return metrics.compactMap { metric in
            let samples = summaries.map { (date: $0.date, value: $0[keyPath: metric.keyPath]) }
            return TrendAnalyzer.analyzeTrend(
                samples: samples,
                metric: metric.name,
                lowerIsBetter: metric.lowerIsBetter,
                period: period
            )
        }
    }

    // MARK: - Per-Pair Trends

    /// One trend per device pair for the selected metric — answers "which pairs are
    /// getting worse". Pairs with fewer than 3 reports cannot be fitted and are listed
    /// as such rather than given a made-up trend.
    private var pairTrends: [PairTrend] {
        let grouped = Dictionary(grouping: filteredSummaries) {
            "\($0.localChip) \u{2192} \($0.remoteChip)"
        }
        return grouped.map { pair, items in
            let sorted = items.sorted { $0.date < $1.date }
            let period = TrendAnalyzer.describePeriod(dates: sorted.map(\.date))
            // nil when the pair has fewer than 3 reports — no trend is invented.
            let trend = TrendAnalyzer.analyzeTrend(
                samples: sorted.map { (date: $0.date, value: metricValue(for: $0)) },
                metric: selectedMetric.rawValue,
                lowerIsBetter: selectedMetric.lowerIsBetter,
                period: period
            )
            return PairTrend(pair: pair, count: sorted.count, trend: trend, period: period)
        }
        .sorted { lhs, rhs in
            let lhsRank = trendRank(lhs.trend?.direction)
            let rhsRank = trendRank(rhs.trend?.direction)
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }
            return abs(lhs.trend?.changePercent ?? 0) > abs(rhs.trend?.changePercent ?? 0)
        }
    }

    /// Worsening pairs sort first; pairs with no fittable trend sort last.
    private func trendRank(_ direction: TrendDirection?) -> Int {
        guard let direction else { return 3 }
        switch direction {
        case .degrading: return 0
        case .stable: return 1
        case .improving: return 2
        }
    }

    private var pairTrendsSection: some View {
        let trends = pairTrends
        return Group {
            if !trends.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "chart.line.downtrend.xyaxis")
                            .foregroundStyle(.orange)
                        Text("\(selectedMetric.rawValue) Trend by Device Pair").font(.headline)
                        Spacer()
                        Text("worsening first").font(.caption).foregroundStyle(.secondary)
                    }

                    ForEach(trends) { item in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.pair).font(.subheadline).fontWeight(.medium)
                                Text("\(item.count) reports · \(item.period)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let trend = item.trend {
                                VStack(alignment: .trailing, spacing: 2) {
                                    HStack(spacing: 4) {
                                        Image(systemName: trend.direction.icon)
                                            .font(.caption)
                                        Text(trend.isFlat
                                            ? "flat"
                                            : String(format: "%+.1f%%", trend.changePercent))
                                            .font(.caption).fontWeight(.semibold)
                                    }
                                    .foregroundStyle(Color.trendColor(trend.direction))
                                    Text(trend.isFlat
                                        ? "no variation"
                                        : String(format: "%.0f%% confidence", trend.confidence * 100))
                                        .font(.system(size: 9))
                                        .foregroundStyle(.tertiary)
                                }
                            } else {
                                Text("needs 3+ reports")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(8)
                        .background(
                            Color.trendColor(item.trend?.direction ?? .stable)
                                .opacity(item.trend == nil ? 0.03 : 0.06),
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                    }
                }
                .padding()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    // MARK: - Trend Chart

    private var trendChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "chart.xyaxis.line").foregroundStyle(.blue)
                Text("\(selectedMetric.rawValue) Over Time").font(.headline)
                Spacer()
                Text("\(filteredSummaries.count) reports").font(.caption).foregroundStyle(.secondary)
            }

            if filteredSummaries.count >= 2 {
                let hasBridges = Set(filteredSummaries.map(\.bridgeTransport)).count > 1
                Chart {
                    ForEach(filteredSummaries) { summary in
                        let pair = "\(summary.localChip) vs \(summary.remoteChip)"
                        LineMark(
                            x: .value("Date", summary.date),
                            y: .value(selectedMetric.rawValue, metricValue(for: summary))
                        )
                        .foregroundStyle(by: .value(
                            hasBridges ? "Bridge" : "Pair",
                            hasBridges ? summary.bridgeTransport : pair
                        ))
                        .interpolationMethod(.catmullRom)
                        .symbol(by: .value("Pair", pair))

                        PointMark(
                            x: .value("Date", summary.date),
                            y: .value(selectedMetric.rawValue, metricValue(for: summary))
                        )
                        .foregroundStyle(by: .value(
                            hasBridges ? "Bridge" : "Pair",
                            hasBridges ? summary.bridgeTransport : pair
                        ))
                        .symbol(by: .value("Pair", pair))
                    }
                }
                .chartYAxisLabel(selectedMetric.unit)
                .frame(height: 220)
            } else {
                Text("Need at least 2 reports to show trends.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(height: 100).frame(maxWidth: .infinity)
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Device Pair Comparison

    private var pairComparisonChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "chart.bar.fill").foregroundStyle(.purple)
                Text("\(selectedMetric.rawValue) by Device Pair").font(.headline)
                Spacer()
            }

            if pairAverages.count >= 1 {
                Chart(pairAverages) { item in
                    BarMark(
                        x: .value(selectedMetric.rawValue, item.average),
                        y: .value("Pair", item.pair)
                    )
                    .foregroundStyle(by: .value("Pair", item.pair))
                    .annotation(position: .trailing, spacing: 4) {
                        Text(formatMetricValue(item.average))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .chartXAxisLabel(selectedMetric.unit)
                .chartLegend(.hidden)
                .frame(height: max(CGFloat(pairAverages.count) * 50, 80))
            } else {
                Text("No data for selected filters.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(height: 80).frame(maxWidth: .infinity)
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Bridge Comparison

    private var bridgeComparisonChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(.teal)
                Text("Bridge Overhead").font(.headline)
                Spacer()
            }

            let bridges = store.availableBridgeTransports()
            let bridgeAverages: [(bridge: String, avg: Double, count: Int)] = bridges.compactMap { bridge in
                let items = filteredSummaries.filter { $0.bridgeTransport == bridge }
                guard !items.isEmpty else { return nil }
                let avg = items.map { metricValue(for: $0) }.reduce(0, +) / Double(items.count)
                return (bridge: bridge, avg: avg, count: items.count)
            }

            if bridgeAverages.count >= 2 {
                Chart(bridgeAverages, id: \.bridge) { item in
                    BarMark(
                        x: .value(selectedMetric.rawValue, item.avg),
                        y: .value("Bridge", item.bridge)
                    )
                    .foregroundStyle(item.bridge == "native" ? Color.blue : Color.orange)
                    .annotation(position: .trailing, spacing: 4) {
                        Text(formatMetricValue(item.avg))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .chartXAxisLabel(selectedMetric.unit)
                .frame(height: max(CGFloat(bridgeAverages.count) * 50, 80))

                // Delta vs native
                if let native = bridgeAverages.first(where: { $0.bridge == "native" }) {
                    VStack(spacing: 4) {
                        ForEach(bridgeAverages.filter { $0.bridge != "native" }, id: \.bridge) { item in
                            let delta = item.avg - native.avg
                            let pctDelta = native.avg > 0 ? (delta / native.avg * 100) : 0
                            HStack {
                                Text(item.bridge).font(.caption).fontWeight(.medium)
                                Spacer()
                                Text(String(format: "%+.1f%@ (%+.0f%%)", delta, selectedMetric.unit, pctDelta))
                                    .font(.caption)
                                    .foregroundStyle(selectedMetric.lowerIsBetter
                                        ? (delta > 0 ? .red : .green)
                                        : (delta > 0 ? .green : .red))
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            } else {
                Text("Need reports from multiple bridges to compare.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(height: 60).frame(maxWidth: .infinity)
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - OS Version Pair Comparison

    private var osPairComparisonChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "arrow.left.arrow.right").foregroundStyle(.indigo)
                Text("\(selectedMetric.rawValue) by OS Version Pair").font(.headline)
                Spacer()
            }

            if !osPairAverages.isEmpty {
                Chart(osPairAverages) { item in
                    BarMark(
                        x: .value(selectedMetric.rawValue, item.average),
                        y: .value("OS Pair", item.pair)
                    )
                    .foregroundStyle(by: .value("OS Pair", item.pair))
                    .annotation(position: .trailing, spacing: 4) {
                        Text(formatMetricValue(item.average))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .chartXAxisLabel(selectedMetric.unit)
                .chartLegend(.hidden)
                .frame(height: max(CGFloat(osPairAverages.count) * 50, 80))
            } else {
                Text("No data for selected filters.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(height: 80).frame(maxWidth: .infinity)
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - OS Version Breakdown

    private var osVersionAggregates: [OSAggregate] {
        var map: [String: [ReportSummary]] = [:]
        for summary in filteredSummaries {
            map[summary.localOS, default: []].append(summary)
            // A report where both devices run the same version belongs to that
            // bucket once, not twice.
            if summary.remoteOS != summary.localOS {
                map[summary.remoteOS, default: []].append(summary)
            }
        }
        return map.map { version, items in
            let n = Double(items.count)
            let failCount = items.filter { $0.overallGrade == "Poor" || $0.overallGrade == "Fair" }.count
            return OSAggregate(
                version: version,
                count: items.count,
                avgLatency: measuredMean(items.compactMap(\.measuredLatencyAvg)) ?? 0,
                avgLatencyP95: measuredMean(items.compactMap(\.measuredLatencyP95)) ?? 0,
                avgThroughputMBps: (measuredMean(items.compactMap(\.measuredThroughput)) ?? 0) / 1_000_000,
                avgJitter: measuredMean(items.compactMap(\.measuredJitter)) ?? 0,
                avgPacketLoss: measuredMean(items.compactMap(\.measuredPacketLoss)) ?? 0,
                avgLoadDegradation: measuredMean(items.map(\.loadDegradation)) ?? 0,
                failRate: Double(failCount) / n * 100
            )
        }
        .sorted { $0.version < $1.version }
    }

    private var osVersionChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "gear.badge").foregroundStyle(.indigo)
                Text("\(selectedMetric.rawValue) by OS Version").font(.headline)
                Spacer()
            }

            let aggregates = osVersionAggregates
            if !aggregates.isEmpty {
                Chart(aggregates) { item in
                    BarMark(
                        x: .value(selectedMetric.rawValue, osMetricValue(for: item)),
                        y: .value("OS", item.version)
                    )
                    .foregroundStyle(by: .value("OS", item.version))
                    .annotation(position: .trailing, spacing: 4) {
                        Text(formatMetricValue(osMetricValue(for: item)))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .chartXAxisLabel(selectedMetric.unit)
                .chartLegend(.hidden)
                .frame(height: max(CGFloat(aggregates.count) * 50, 80))

                // Detail table
                VStack(spacing: 4) {
                    HStack {
                        Text("Version").font(.caption2).fontWeight(.semibold).frame(
                            maxWidth: .infinity,
                            alignment: .leading
                        )
                        Text("Tests").font(.caption2).fontWeight(.semibold).frame(width: 50, alignment: .trailing)
                        Text("Avg Lat").font(.caption2).fontWeight(.semibold).frame(width: 60, alignment: .trailing)
                        Text("Loss").font(.caption2).fontWeight(.semibold).frame(width: 50, alignment: .trailing)
                        Text("Fail Rate").font(.caption2).fontWeight(.semibold).frame(width: 60, alignment: .trailing)
                    }
                    .foregroundStyle(.secondary)

                    ForEach(aggregates) { item in
                        HStack {
                            Text(item.version).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                            Text("\(item.count)").font(.caption).frame(width: 50, alignment: .trailing)
                            Text(String(format: "%.1fms", item.avgLatency)).font(.caption).frame(
                                width: 60,
                                alignment: .trailing
                            )
                            Text(String(format: "%.1f%%", item.avgPacketLoss)).font(.caption).frame(
                                width: 50,
                                alignment: .trailing
                            )
                            Text(String(format: "%.1f%%", item.failRate)).font(.caption)
                                .foregroundStyle(item.failRate > 10 ? .red : .primary)
                                .frame(width: 60, alignment: .trailing)
                        }
                    }
                }
                .padding(.top, 8)
            } else {
                Text("No data for selected filters.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(height: 80).frame(maxWidth: .infinity)
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    /// Exhaustive on purpose — no `default`, so a new metric fails to compile rather
    /// than silently plotting latency under another metric's label.
    private func osMetricValue(for item: OSAggregate) -> Double {
        switch selectedMetric {
        case .latencyAvg: item.avgLatency
        case .latencyP95: item.avgLatencyP95
        case .throughput: item.avgThroughputMBps
        case .jitterAvg: item.avgJitter
        case .packetLoss: item.avgPacketLoss
        case .loadDegradation: item.avgLoadDegradation
        }
    }

    // MARK: - Grade Distribution

    private var gradeChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "chart.pie.fill").foregroundStyle(.green)
                Text("Grade Distribution").font(.headline)
                Spacer()
                Text("\(filteredSummaries.count) reports").font(.caption).foregroundStyle(.secondary)
            }

            if !gradeDistribution.isEmpty {
                HStack(spacing: 16) {
                    Chart(gradeDistribution, id: \.grade) { item in
                        SectorMark(
                            angle: .value("Count", item.count),
                            innerRadius: .ratio(0.5),
                            angularInset: 2
                        )
                        .foregroundStyle(item.color)
                    }
                    .frame(width: 150, height: 150)

                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(gradeDistribution, id: \.grade) { item in
                            HStack(spacing: 6) {
                                Circle().fill(item.color).frame(width: 10, height: 10)
                                Text(item.grade).font(.subheadline)
                                Spacer()
                                Text("\(item.count)").font(.subheadline).fontWeight(.semibold)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("No graded reports.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(height: 80).frame(maxWidth: .infinity)
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Helpers

    private func metricValue(for summary: ReportSummary) -> Double {
        switch selectedMetric {
        case .latencyAvg: summary.latencyAvg
        case .latencyP95: summary.latencyP95
        case .throughput: summary.throughputBps / 1_000_000
        case .jitterAvg: summary.jitterAvg
        case .packetLoss: summary.packetLossPercent
        case .loadDegradation: summary.loadDegradation
        }
    }

    private func formatMetricValue(_ value: Double) -> String {
        switch selectedMetric {
        case .latencyAvg, .latencyP95, .jitterAvg:
            String(format: "%.1f%@", value, selectedMetric.unit)
        case .throughput:
            String(format: "%.1f %@", value, selectedMetric.unit)
        case .packetLoss, .loadDegradation:
            String(format: "%.1f%@", value, selectedMetric.unit)
        }
    }

    private func summaryItem(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.subheadline)
                .fontWeight(.bold)
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(8)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct PairAggregate: Identifiable {
    let pair: String
    let average: Double
    let count: Int
    let bridge: String?
    var id: String {
        if let bridge {
            return "\(pair)|\(bridge)"
        }
        return pair
    }

    init(pair: String, average: Double, count: Int, bridge: String? = nil) {
        self.pair = pair
        self.average = average
        self.count = count
        self.bridge = bridge
    }
}

private struct OSAggregate: Identifiable {
    let version: String
    let count: Int
    let avgLatency: Double
    let avgLatencyP95: Double
    let avgThroughputMBps: Double
    let avgJitter: Double
    let avgPacketLoss: Double
    let avgLoadDegradation: Double
    let failRate: Double
    var id: String {
        version
    }
}

private struct PairTrend: Identifiable {
    let pair: String
    let count: Int
    /// nil when the pair has too few reports to fit a regression.
    let trend: TrendResult?
    let period: String
    var id: String {
        pair
    }
}

private struct OSPairAggregate: Identifiable {
    let pair: String
    let average: Double
    let count: Int
    var id: String {
        pair
    }
}
