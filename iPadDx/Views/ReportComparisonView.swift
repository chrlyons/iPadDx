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

                // DNS Resolution section
                sectionTitle("DNS Resolution", icon: "magnifyingglass.circle.fill", color: .cyan)
                comparisonRow(
                    "Time",
                    fmtOpt(dnsTime(reportA), "%.0fms"),
                    fmtOpt(dnsTime(reportB), "%.0fms"),
                    valueA: dnsTime(reportA),
                    valueB: dnsTime(reportB),
                    lowerIsBetter: true
                )
                comparisonRow(
                    "Resolved",
                    resolvedLabel(reportA),
                    resolvedLabel(reportB),
                    lowerIsBetter: false
                )

                // Latency section
                sectionTitle("Latency Burst", icon: "bolt.fill", color: .blue)
                comparisonRow(
                    "Min",
                    fmtOpt(reportA.results.hasLatency ? reportA.results.latencyBurst.min : nil),
                    fmtOpt(reportB.results.hasLatency ? reportB.results.latencyBurst.min : nil),
                    valueA: reportA.results.hasLatency ? reportA.results.latencyBurst.min : nil,
                    valueB: reportB.results.hasLatency ? reportB.results.latencyBurst.min : nil,
                    lowerIsBetter: true
                )
                comparisonRow(
                    "Max",
                    fmtOpt(reportA.results.hasLatency ? reportA.results.latencyBurst.max : nil),
                    fmtOpt(reportB.results.hasLatency ? reportB.results.latencyBurst.max : nil),
                    valueA: reportA.results.hasLatency ? reportA.results.latencyBurst.max : nil,
                    valueB: reportB.results.hasLatency ? reportB.results.latencyBurst.max : nil,
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
                    fmtOpt(reportA.results.hasLatency ? reportA.results.latencyBurst.median : nil),
                    fmtOpt(reportB.results.hasLatency ? reportB.results.latencyBurst.median : nil),
                    valueA: reportA.results.hasLatency ? reportA.results.latencyBurst.median : nil,
                    valueB: reportB.results.hasLatency ? reportB.results.latencyBurst.median : nil,
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
                    reportA.results.hasThroughput ? reportA.results.sustainedThroughput.formattedSpeed : "—",
                    reportB.results.hasThroughput ? reportB.results.sustainedThroughput.formattedSpeed : "—",
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
                    fmtOpt(reportA.results.hasJitter ? reportA.results.jitterMeasurement.maxJitter : nil),
                    fmtOpt(reportB.results.hasJitter ? reportB.results.jitterMeasurement.maxJitter : nil),
                    valueA: reportA.results.hasJitter ? reportA.results.jitterMeasurement.maxJitter : nil,
                    valueB: reportB.results.hasJitter ? reportB.results.jitterMeasurement.maxJitter : nil,
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
                    fmtOpt(reportA.results.hasLoadDegradation ? reportA.results.latencyUnderLoad.baselineAvg : nil),
                    fmtOpt(reportB.results.hasLoadDegradation ? reportB.results.latencyUnderLoad.baselineAvg : nil),
                    valueA: reportA.results.hasLoadDegradation ? reportA.results.latencyUnderLoad.baselineAvg : nil,
                    valueB: reportB.results.hasLoadDegradation ? reportB.results.latencyUnderLoad.baselineAvg : nil,
                    lowerIsBetter: true
                )
                comparisonRow(
                    "Under Load",
                    fmtOpt(reportA.results.latencyUnderLoad.sampleCount > 0 ? reportA.results.latencyUnderLoad
                        .underLoadAvg : nil),
                    fmtOpt(reportB.results.latencyUnderLoad.sampleCount > 0 ? reportB.results.latencyUnderLoad
                        .underLoadAvg : nil),
                    valueA: reportA.results.latencyUnderLoad.sampleCount > 0 ? reportA.results.latencyUnderLoad
                        .underLoadAvg : nil,
                    valueB: reportB.results.latencyUnderLoad.sampleCount > 0 ? reportB.results.latencyUnderLoad
                        .underLoadAvg : nil,
                    lowerIsBetter: true
                )
                comparisonRow(
                    "Impact",
                    reportA.results.hasLoadDegradation
                        ? reportA.results.latencyUnderLoad.formattedDegradation : "—",
                    reportB.results.hasLoadDegradation
                        ? reportB.results.latencyUnderLoad.formattedDegradation : "—",
                    valueA: reportA.results.measuredLoadDegradation,
                    valueB: reportB.results.measuredLoadDegradation,
                    lowerIsBetter: true
                )

                // Heavy Load
                sectionTitle("Heavy Load Stress", icon: "cpu", color: .red)
                comparisonRow(
                    "Avg Latency",
                    fmtOpt(heavyLoad(reportA)?.avgLatency),
                    fmtOpt(heavyLoad(reportB)?.avgLatency),
                    valueA: heavyLoad(reportA)?.avgLatency,
                    valueB: heavyLoad(reportB)?.avgLatency,
                    lowerIsBetter: true
                )
                comparisonRow(
                    "Max Latency",
                    fmtOpt(heavyLoad(reportA)?.maxLatency),
                    fmtOpt(heavyLoad(reportB)?.maxLatency),
                    valueA: heavyLoad(reportA)?.maxLatency,
                    valueB: heavyLoad(reportB)?.maxLatency,
                    lowerIsBetter: true
                )
                comparisonRow(
                    "Speed",
                    heavyLoad(reportA)?.formattedThroughput ?? "—",
                    heavyLoad(reportB)?.formattedThroughput ?? "—",
                    valueA: heavyLoad(reportA)?.throughputBps,
                    valueB: heavyLoad(reportB)?.throughputBps,
                    lowerIsBetter: false
                )
                comparisonRow(
                    "Loss %",
                    fmtOpt(heavyLoad(reportA)?.packetLoss, "%.1f%%"),
                    fmtOpt(heavyLoad(reportB)?.packetLoss, "%.1f%%"),
                    valueA: heavyLoad(reportA)?.packetLoss,
                    valueB: heavyLoad(reportB)?.packetLoss,
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

    /// Phase 0's resolution time, or nil when the browse never resolved the peer.
    ///
    /// A failed browse stores the elapsed timeout, which would otherwise be compared as
    /// though it were a (merely slow) resolution — and against a report that skipped the
    /// phase entirely, ranked as the winner.
    private func dnsTime(_ report: TestReport) -> Double? {
        report.results.hasDNSResolution ? report.results.dnsResolution?.resolutionTimeMs : nil
    }

    /// "—" when the phase never ran, so a skipped phase is never shown as a failure.
    private func resolvedLabel(_ report: TestReport) -> String {
        guard let dns = report.results.dnsResolution else { return "—" }
        return dns.resolved ? "Yes" : "No"
    }

    /// Phase 6's results, or nil when the phase produced no probes — including reports
    /// stored before Heavy Load was persisted at all.
    private func heavyLoad(_ report: TestReport) -> HeavyLoadResult? {
        report.results.hasHeavyLoad ? report.results.heavyLoad : nil
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
