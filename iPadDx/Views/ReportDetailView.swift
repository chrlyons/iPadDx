import Charts
import SwiftUI

struct ReportDetailView: View {
    let reportID: UUID
    var preloadedReport: TestReport?
    @Environment(ReportStore.self) private var store
    @State private var report: TestReport?
    @State private var exportItem: ExportItem?

    /// Convenience init for direct report access (e.g., from conductor completed reports).
    init(report: TestReport) {
        reportID = report.id
        preloadedReport = report
    }

    /// On-demand loading init (e.g., from report list).
    init(reportID: UUID) {
        self.reportID = reportID
        preloadedReport = nil
    }

    var body: some View {
        Group {
            if let report {
                reportContent(report)
            } else {
                ProgressView("Loading report…")
                    .task {
                        report = preloadedReport ?? store.loadFullReport(id: reportID)
                    }
            }
        }
    }

    private func reportContent(_ report: TestReport) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                gradeHeader(report)
                devicePairCard(report)

                if !report.results.latencyBurst.samples.isEmpty {
                    latencyChartCard(report)
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
                Button {
                    Task.detached {
                        let url = await store.exportCSV(for: report)
                        await MainActor.run {
                            if let url { exportItem = ExportItem(urls: [url]) }
                        }
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .sheet(item: $exportItem) { item in
            ShareSheet(activityItems: item.urls)
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
            }
            .chartYAxisLabel("ms")
            .chartXAxis(.hidden)
            .frame(height: 150)
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
        switch grade {
        case "Excellent": .green
        case "Good": .blue
        case "Fair": .orange
        default: .red
        }
    }

    private func formatBytes(_ bytes: Int) -> String {
        if bytes >= 1_000_000 { return String(format: "%.1f MB", Double(bytes) / 1_000_000) }
        if bytes >= 1000 { return String(format: "%.1f KB", Double(bytes) / 1000) }
        return "\(bytes) B"
    }
}
