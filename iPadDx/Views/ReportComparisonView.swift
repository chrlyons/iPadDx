import SwiftUI

struct ReportComparisonView: View {
    let reportA: TestReport
    let reportB: TestReport

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Headers
                // A and B follow the order the reports were selected, not fetch order.
                HStack(spacing: 12) {
                    reportHeader(reportA, label: "Report A · selected first")
                    reportHeader(reportB, label: "Report B · selected second")
                }

                // Grade comparison
                comparisonRow(
                    "Overall Grade",
                    reportA.results.overallGrade,
                    reportB.results.overallGrade,
                    lowerIsBetter: false
                )

                // Bridge info (if different)
                let bridgeA = reportA.bridgeTransport ?? "native"
                let bridgeB = reportB.bridgeTransport ?? "native"
                if bridgeA != bridgeB {
                    comparisonRow("Bridge", bridgeA, bridgeB, lowerIsBetter: false)
                }

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
                    fmtOpt(reportA.results.measuredLatencyAvg),
                    fmtOpt(reportB.results.measuredLatencyAvg),
                    valueA: reportA.results.measuredLatencyAvg,
                    valueB: reportB.results.measuredLatencyAvg,
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
                    fmtOpt(reportA.results.measuredLatencyP95),
                    fmtOpt(reportB.results.measuredLatencyP95),
                    valueA: reportA.results.measuredLatencyP95,
                    valueB: reportB.results.measuredLatencyP95,
                    lowerIsBetter: true
                )

                // Throughput section
                sectionTitle("Throughput", icon: "arrow.up.arrow.down.circle.fill", color: .purple)
                comparisonRow(
                    "Speed",
                    reportA.results.sustainedThroughput.formattedSpeed,
                    reportB.results.sustainedThroughput.formattedSpeed,
                    valueA: reportA.results.measuredThroughput,
                    valueB: reportB.results.measuredThroughput,
                    lowerIsBetter: false
                )

                // Jitter section
                sectionTitle("Jitter", icon: "waveform.path", color: .orange)
                comparisonRow(
                    "Average",
                    fmtOpt(reportA.results.measuredJitter),
                    fmtOpt(reportB.results.measuredJitter),
                    valueA: reportA.results.measuredJitter,
                    valueB: reportB.results.measuredJitter,
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
                    fmtOpt(reportA.results.measuredPacketLoss, "%.1f%%"),
                    fmtOpt(reportB.results.measuredPacketLoss, "%.1f%%"),
                    valueA: reportA.results.measuredPacketLoss,
                    valueB: reportB.results.measuredPacketLoss,
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
                    "Impact",
                    reportA.results.latencyUnderLoad.formattedDegradation,
                    reportB.results.latencyUnderLoad.formattedDegradation,
                    valueA: reportA.results.measuredLoadDegradation,
                    valueB: reportB.results.measuredLoadDegradation,
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
            if let bridge = report.bridgeTransport, bridge != "native" {
                Text(bridge)
                    .font(.caption2).fontWeight(.medium)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.orange.opacity(0.12), in: Capsule())
            }
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
            if lowerIsBetter {
                return a < b ? 0 : 1
            }
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

    /// Renders a metric that a report may never have measured.
    ///
    /// A cancelled or partial run stores zero, and "0.00ms" in a side-by-side reads as
    /// the *better* result. Show it as not measured instead.
    private func fmtOpt(_ value: Double?, _ format: String = "%.2fms") -> String {
        guard let value else { return "—" }
        return String(format: format, value)
    }
}
