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

private enum DateRange: String, CaseIterable, Identifiable {
    case all = "All Time"
    case week = "7 Days"
    case month = "30 Days"
    case quarter = "90 Days"

    var id: String {
        rawValue
    }

    var startDate: Date? {
        switch self {
        case .all: nil
        case .week: Calendar.current.date(byAdding: .day, value: -7, to: Date())
        case .month: Calendar.current.date(byAdding: .day, value: -30, to: Date())
        case .quarter: Calendar.current.date(byAdding: .day, value: -90, to: Date())
        }
    }
}

struct ReportAnalyticsView: View {
    @Environment(ReportStore.self) private var store
    @State private var selectedPair: String = "All"
    @State private var dateRange: DateRange = .all
    @State private var selectedMetric: AnalyticsMetric = .latencyAvg
    @State private var exportURLs: [URL]?

    private var uniquePairs: [String] {
        let pairs = store.reports.map { "\($0.localDevice.chipFamily) vs \($0.remoteDevice.chipFamily)" }
        return Array(Set(pairs)).sorted()
    }

    private var filteredReports: [TestReport] {
        store.reports.filter { report in
            let pair = "\(report.localDevice.chipFamily) vs \(report.remoteDevice.chipFamily)"
            let matchesPair = selectedPair == "All" || pair == selectedPair
            let matchesDate = dateRange.startDate.map { report.date >= $0 } ?? true
            return matchesPair && matchesDate
        }
        .sorted { $0.date < $1.date }
    }

    private var pairAverages: [PairAggregate] {
        let grouped = Dictionary(grouping: filteredReports) {
            "\($0.localDevice.chipFamily) vs \($0.remoteDevice.chipFamily)"
        }
        return grouped.map { pair, reports in
            let avg = reports.map { metricValue(for: $0) }.reduce(0, +) / Double(reports.count)
            return PairAggregate(pair: pair, average: avg, count: reports.count)
        }
        .sorted { $0.pair < $1.pair }
    }

    private var gradeDistribution: [(grade: String, count: Int, color: Color)] {
        let grades = ["Excellent", "Good", "Fair", "Poor"]
        let colors: [Color] = [.green, .blue, .orange, .red]
        let reports = filteredReports
        var result: [(grade: String, count: Int, color: Color)] = []
        for i in 0 ..< grades.count {
            let gradeCount = reports.filter { $0.results.overallGrade == grades[i] }.count
            if gradeCount > 0 {
                result.append((grade: grades[i], count: gradeCount, color: colors[i]))
            }
        }
        return result
    }

    var body: some View {
        ScrollView {
            if store.reports.isEmpty {
                emptyState
            } else {
                VStack(spacing: 16) {
                    filterBar
                    summaryCards
                    trendChart
                    pairComparisonChart
                    gradeChart
                }
                .padding()
            }
        }
        .navigationTitle("Analytics")
        .toolbar {
            if !store.reports.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        exportAnalytics()
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { exportURLs != nil },
            set: { if !$0 { exportURLs = nil } }
        )) {
            if let urls = exportURLs {
                ShareSheet(activityItems: urls)
                    .presentationDetents([.medium, .large])
            }
        }
    }

    private func exportAnalytics() {
        var urls: [URL] = []
        // PDF report
        if let pdfURL = AnalyticsReportRenderer.renderPDF(reports: filteredReports) {
            urls.append(pdfURL)
        }
        // CSV raw data as companion
        if let summaryURL = store.exportSummaryCSV(for: filteredReports) {
            urls.append(summaryURL)
        }
        if !urls.isEmpty {
            exportURLs = urls
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
        HStack(spacing: 12) {
            Picker("Pair", selection: $selectedPair) {
                Text("All Pairs").tag("All")
                ForEach(uniquePairs, id: \.self) { pair in
                    Text(pair).tag(pair)
                }
            }
            .pickerStyle(.menu)

            Picker("Range", selection: $dateRange) {
                ForEach(DateRange.allCases) { range in
                    Text(range.rawValue).tag(range)
                }
            }
            .pickerStyle(.segmented)

            Picker("Metric", selection: $selectedMetric) {
                ForEach(AnalyticsMetric.allCases) { metric in
                    Text(metric.rawValue).tag(metric)
                }
            }
            .pickerStyle(.menu)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Summary Cards

    private var summaryCards: some View {
        let reports = filteredReports
        let count = reports.count

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
                count > 0
                    ? String(format: "%.1fms", reports.map(\.results.latencyBurst.avg).reduce(0, +) / Double(count))
                    : "-",
                .blue
            )
            summaryItem(
                "Avg Throughput",
                count > 0
                    ? String(
                        format: "%.1f MB/s",
                        reports.map(\.results.sustainedThroughput.bytesPerSecond)
                            .reduce(0, +) / Double(count) / 1_000_000
                    )
                    : "-",
                .purple
            )
            summaryItem(
                "Avg Jitter",
                count > 0
                    ? String(
                        format: "%.1fms",
                        reports.map(\.results.jitterMeasurement.averageJitter).reduce(0, +) / Double(count)
                    )
                    : "-",
                .orange
            )
            summaryItem(
                "Avg Loss",
                count > 0
                    ? String(
                        format: "%.1f%%",
                        reports.map(\.results.packetLossStress.lostPercent).reduce(0, +) / Double(count)
                    )
                    : "-",
                .red
            )
            summaryItem("Device Pairs", "\(uniquePairs.count)", .indigo)
        }
    }

    // MARK: - Trend Chart

    private var trendChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "chart.xyaxis.line").foregroundStyle(.blue)
                Text("\(selectedMetric.rawValue) Over Time").font(.headline)
                Spacer()
                Text("\(filteredReports.count) reports").font(.caption).foregroundStyle(.secondary)
            }

            if filteredReports.count >= 2 {
                Chart {
                    ForEach(filteredReports) { report in
                        let pair = "\(report.localDevice.chipFamily) vs \(report.remoteDevice.chipFamily)"
                        LineMark(
                            x: .value("Date", report.date),
                            y: .value(selectedMetric.rawValue, metricValue(for: report))
                        )
                        .foregroundStyle(by: .value("Pair", pair))
                        .interpolationMethod(.catmullRom)
                        .symbol(by: .value("Pair", pair))

                        PointMark(
                            x: .value("Date", report.date),
                            y: .value(selectedMetric.rawValue, metricValue(for: report))
                        )
                        .foregroundStyle(by: .value("Pair", pair))
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

    // MARK: - Grade Distribution

    private var gradeChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "chart.pie.fill").foregroundStyle(.green)
                Text("Grade Distribution").font(.headline)
                Spacer()
                Text("\(filteredReports.count) reports").font(.caption).foregroundStyle(.secondary)
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

    private func metricValue(for report: TestReport) -> Double {
        switch selectedMetric {
        case .latencyAvg: report.results.latencyBurst.avg
        case .latencyP95: report.results.latencyBurst.p95
        case .throughput: report.results.sustainedThroughput.bytesPerSecond / 1_000_000
        case .jitterAvg: report.results.jitterMeasurement.averageJitter
        case .packetLoss: report.results.packetLossStress.lostPercent
        case .loadDegradation: report.results.latencyUnderLoad.degradationPercent
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
    var id: String {
        pair
    }
}
