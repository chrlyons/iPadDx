import Charts
import SwiftUI

struct ReportDetailView: View {
    let report: TestReport
    @Environment(ReportStore.self) private var store
    @State private var exportItem: ExportItem?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Header
                gradeHeader

                // Device pair
                devicePairCard

                // Latency chart
                if !report.results.latencyBurst.samples.isEmpty {
                    latencyChartCard
                }

                // Latency stats
                latencyCard

                // Throughput
                throughputCard

                // Jitter
                jitterCard

                // Packet loss
                packetLossCard

                // Latency under load
                latencyUnderLoadCard

                // System metrics
                systemMetricsCard
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

    private var gradeHeader: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("Overall Grade")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(report.results.overallGrade)
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundStyle(gradeColor(report.results.overallGrade))
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

    private var devicePairCard: some View {
        HStack {
            deviceColumn("Local", report.localDevice)
            Spacer()
            VStack {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            deviceColumn("Remote", report.remoteDevice)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var latencyChartCard: some View {
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

    private var latencyCard: some View {
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

    private var throughputCard: some View {
        resultCard("Throughput", icon: "arrow.up.arrow.down.circle.fill", color: .purple) {
            let t = report.results.sustainedThroughput
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 8) {
                statItem("Speed", t.formattedSpeed, .purple)
                statItem("Data", formatBytes(t.totalBytes), .cyan)
                statItem("Duration", String(format: "%.1fs", t.durationSeconds), .gray)
            }
        }
    }

    private var jitterCard: some View {
        resultCard("Jitter", icon: "waveform.path", color: .orange) {
            let j = report.results.jitterMeasurement
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 8) {
                statItem("Average", String(format: "%.2fms", j.averageJitter), .orange)
                statItem("Max", String(format: "%.2fms", j.maxJitter), .red)
                statItem("Samples", "\(j.sampleCount)", .gray)
            }
        }
    }

    private var packetLossCard: some View {
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

    private var latencyUnderLoadCard: some View {
        resultCard("Latency Under Load", icon: "flame.fill", color: .orange) {
            let l = report.results.latencyUnderLoad
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 8) {
                statItem("Baseline", String(format: "%.1fms", l.baselineAvg), .blue)
                statItem("Under Load", String(format: "%.1fms", l.underLoadAvg), .orange)
                statItem(
                    "Degradation",
                    String(format: "%.0f%%", l.degradationPercent),
                    l.degradationPercent < 50 ? .green : l.degradationPercent < 100 ? .orange : .red
                )
                statItem("Samples", "\(l.sampleCount)", .gray)
            }
        }
    }

    private var systemMetricsCard: some View {
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
