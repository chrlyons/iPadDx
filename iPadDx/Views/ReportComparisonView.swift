import SwiftUI

struct ReportComparisonView: View {
    let reportA: TestReport
    let reportB: TestReport

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Headers
                HStack(spacing: 12) {
                    reportHeader(reportA, label: "Report A")
                    reportHeader(reportB, label: "Report B")
                }

                // Grade comparison
                comparisonRow(
                    "Overall Grade",
                    reportA.results.overallGrade,
                    reportB.results.overallGrade,
                    lowerIsBetter: false
                )

                // Latency section
                sectionTitle("Latency Burst", icon: "bolt.fill", color: .blue)
                comparisonRow(
                    "Min",
                    fmt(reportA.results.latencyBurst.min),
                    fmt(reportB.results.latencyBurst.min),
                    valueA: reportA.results.latencyBurst.min,
                    valueB: reportB.results.latencyBurst.min,
                    lowerIsBetter: true
                )
                comparisonRow(
                    "Max",
                    fmt(reportA.results.latencyBurst.max),
                    fmt(reportB.results.latencyBurst.max),
                    valueA: reportA.results.latencyBurst.max,
                    valueB: reportB.results.latencyBurst.max,
                    lowerIsBetter: true
                )
                comparisonRow(
                    "Avg",
                    fmt(reportA.results.latencyBurst.avg),
                    fmt(reportB.results.latencyBurst.avg),
                    valueA: reportA.results.latencyBurst.avg,
                    valueB: reportB.results.latencyBurst.avg,
                    lowerIsBetter: true
                )
                comparisonRow(
                    "Median",
                    fmt(reportA.results.latencyBurst.median),
                    fmt(reportB.results.latencyBurst.median),
                    valueA: reportA.results.latencyBurst.median,
                    valueB: reportB.results.latencyBurst.median,
                    lowerIsBetter: true
                )
                comparisonRow(
                    "P95",
                    fmt(reportA.results.latencyBurst.p95),
                    fmt(reportB.results.latencyBurst.p95),
                    valueA: reportA.results.latencyBurst.p95,
                    valueB: reportB.results.latencyBurst.p95,
                    lowerIsBetter: true
                )

                // Throughput section
                sectionTitle("Throughput", icon: "arrow.up.arrow.down.circle.fill", color: .purple)
                comparisonRow(
                    "Speed",
                    reportA.results.sustainedThroughput.formattedSpeed,
                    reportB.results.sustainedThroughput.formattedSpeed,
                    valueA: reportA.results.sustainedThroughput.bytesPerSecond,
                    valueB: reportB.results.sustainedThroughput.bytesPerSecond,
                    lowerIsBetter: false
                )

                // Jitter section
                sectionTitle("Jitter", icon: "waveform.path", color: .orange)
                comparisonRow(
                    "Average",
                    fmt(reportA.results.jitterMeasurement.averageJitter),
                    fmt(reportB.results.jitterMeasurement.averageJitter),
                    valueA: reportA.results.jitterMeasurement.averageJitter,
                    valueB: reportB.results.jitterMeasurement.averageJitter,
                    lowerIsBetter: true
                )
                comparisonRow(
                    "Max",
                    fmt(reportA.results.jitterMeasurement.maxJitter),
                    fmt(reportB.results.jitterMeasurement.maxJitter),
                    valueA: reportA.results.jitterMeasurement.maxJitter,
                    valueB: reportB.results.jitterMeasurement.maxJitter,
                    lowerIsBetter: true
                )

                // Packet Loss section
                sectionTitle("Packet Loss", icon: "exclamationmark.triangle.fill", color: .red)
                comparisonRow(
                    "Loss %",
                    String(format: "%.1f%%", reportA.results.packetLossStress.lostPercent),
                    String(format: "%.1f%%", reportB.results.packetLossStress.lostPercent),
                    valueA: reportA.results.packetLossStress.lostPercent,
                    valueB: reportB.results.packetLossStress.lostPercent,
                    lowerIsBetter: true
                )
                // Latency Under Load
                sectionTitle("Latency Under Load", icon: "flame.fill", color: .orange)
                comparisonRow(
                    "Baseline",
                    fmt(reportA.results.latencyUnderLoad.baselineAvg),
                    fmt(reportB.results.latencyUnderLoad.baselineAvg),
                    valueA: reportA.results.latencyUnderLoad.baselineAvg,
                    valueB: reportB.results.latencyUnderLoad.baselineAvg,
                    lowerIsBetter: true
                )
                comparisonRow(
                    "Under Load",
                    fmt(reportA.results.latencyUnderLoad.underLoadAvg),
                    fmt(reportB.results.latencyUnderLoad.underLoadAvg),
                    valueA: reportA.results.latencyUnderLoad.underLoadAvg,
                    valueB: reportB.results.latencyUnderLoad.underLoadAvg,
                    lowerIsBetter: true
                )
                comparisonRow(
                    "Degradation",
                    String(format: "%.0f%%", reportA.results.latencyUnderLoad.degradationPercent),
                    String(format: "%.0f%%", reportB.results.latencyUnderLoad.degradationPercent),
                    valueA: reportA.results.latencyUnderLoad.degradationPercent,
                    valueB: reportB.results.latencyUnderLoad.degradationPercent,
                    lowerIsBetter: true
                )

                // System
                sectionTitle("System", icon: "cpu", color: .indigo)
                comparisonRow(
                    "Battery Drain",
                    String(format: "%.2f%%", reportA.results.systemMetrics.batteryDrainPercent),
                    String(format: "%.2f%%", reportB.results.systemMetrics.batteryDrainPercent),
                    valueA: reportA.results.systemMetrics.batteryDrainPercent,
                    valueB: reportB.results.systemMetrics.batteryDrainPercent,
                    lowerIsBetter: true
                )
                comparisonRow(
                    "Peak CPU",
                    String(format: "%.0f%%", reportA.results.systemMetrics.peakCpuUsage),
                    String(format: "%.0f%%", reportB.results.systemMetrics.peakCpuUsage),
                    valueA: reportA.results.systemMetrics.peakCpuUsage,
                    valueB: reportB.results.systemMetrics.peakCpuUsage,
                    lowerIsBetter: true
                )
            }
            .padding()
        }
        .navigationTitle("Comparison")
    }

    // MARK: - Components

    private func reportHeader(_ report: TestReport, label: String) -> some View {
        VStack(spacing: 6) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("\(report.localDevice.chipFamily) vs \(report.remoteDevice.chipFamily)")
                .font(.subheadline)
                .fontWeight(.bold)
            Text(report.localDevice.name)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(report.date, style: .date)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func sectionTitle(_ title: String, icon: String, color: Color) -> some View {
        HStack {
            Image(systemName: icon).foregroundStyle(color)
            Text(title).font(.headline)
            Spacer()
        }
        .padding(.top, 8)
    }

    private func comparisonRow(
        _ label: String,
        _ valueA: String,
        _ valueB: String,
        valueA numA: Double? = nil,
        valueB numB: Double? = nil,
        lowerIsBetter: Bool
    ) -> some View {
        let betterSide: Int? = {
            guard let a = numA, let b = numB, a != b else { return nil }
            if lowerIsBetter { return a < b ? 0 : 1 }
            return a > b ? 0 : 1
        }()

        return HStack {
            Text(valueA)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(betterSide == 0 ? .green : (betterSide == 1 ? .red : .primary))
                .frame(maxWidth: .infinity)

            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 70)

            Text(valueB)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(betterSide == 1 ? .green : (betterSide == 0 ? .red : .primary))
                .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 6)
        .padding(.horizontal)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func fmt(_ value: Double) -> String {
        String(format: "%.2fms", value)
    }
}
