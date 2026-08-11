import Charts
import SwiftUI

struct DiagnosticDashboardView: View {
    let peer: PeerDevice
    @Environment(BonjourService.self) private var service
    @Environment(\.colorScheme) private var colorScheme
    @State private var uptimeTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var uptimeDisplay: String = "0m 00s"
    @State private var showAnomalies = false
    @State private var latencyWindow: LatencyWindow = .all

    private var metrics: DiagnosticMetrics {
        peer.metrics
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                headerSection

                // MARK: — Connection Metrics (between devices)

                dashboardSectionLabel(
                    "Connection",
                    icon: "arrow.left.arrow.right.circle.fill",
                    color: Color.adaptive(.blue, scheme: colorScheme)
                )

                LazyVGrid(columns: threeColumns, spacing: 12) {
                    signalQualityCard
                    latencyCard
                    connectionInfoCard
                }

                latencyChartSection

                LazyVGrid(columns: fourColumns, spacing: 12) {
                    MetricGaugeView(
                        title: "Min Latency", value: String(format: "%.1fms", metrics.latencyMin),
                        subtitle: "All-time low", icon: "arrow.down",
                        color: Color.latencyColor(metrics.latencyMin, scheme: colorScheme),
                        tooltip: "The lowest round-trip latency recorded during this session."
                    )
                    MetricGaugeView(
                        title: "Max Latency", value: String(format: "%.1fms", metrics.latencyMax),
                        subtitle: "All-time high", icon: "arrow.up",
                        color: Color.latencyColor(metrics.latencyMax, scheme: colorScheme),
                        tooltip: "The highest round-trip latency recorded. Spikes indicate congestion or interference."
                    )
                    MetricGaugeView(
                        title: "Avg Latency", value: String(format: "%.1fms", metrics.latencyAvg),
                        subtitle: "Overall average", icon: "equal",
                        color: Color.latencyColor(metrics.latencyAvg, scheme: colorScheme),
                        tooltip: "Mean round-trip latency across all samples."
                    )
                    MetricGaugeView(
                        title: "Jitter", value: String(format: "%.1fms", metrics.jitterMs),
                        subtitle: "Latency variation", icon: "waveform.path",
                        color: Color.thresholdColor(metrics.jitterMs, good: 5, caution: 15, scheme: colorScheme),
                        tooltip: "Average difference between consecutive latency measurements. Low jitter (<5ms) = stable connection."
                    )
                }

                HStack(spacing: 12) {
                    ThroughputTestView(metrics: metrics) {
                        service.engine?.runThroughputTest()
                    }
                    connectionHealthCard
                }

                HStack(spacing: 12) {
                    dataTransferCard
                    networkPathSection
                }

                // MARK: — Local Device

                dashboardSectionLabel("This Device", icon: "ipad", color: Color.adaptive(.green, scheme: colorScheme))

                LazyVGrid(columns: fourColumns, spacing: 12) {
                    MetricGaugeView(
                        title: "Battery", value: metrics.batteryPercent,
                        subtitle: "Drain: \(metrics.batteryDrain)", icon: "battery.75percent",
                        color: Color.thresholdColor(
                            Double(metrics.batteryLevel) * 100,
                            good: 50, caution: 20, higherIsBetter: true, scheme: colorScheme
                        ),
                        tooltip: "Current battery level and drain since connection started."
                    )
                    MetricGaugeView(
                        title: "Thermal", value: metrics.thermalState,
                        subtitle: metrics.batteryState, icon: "thermometer.medium",
                        color: Color.thermalColor(metrics.thermalState, scheme: colorScheme),
                        tooltip: "Device thermal state. Serious/Critical may throttle performance."
                    )
                    MetricGaugeView(
                        title: "CPU", value: String(format: "%.0f%%", metrics.cpuUsage),
                        subtitle: SystemMonitor.cpuUsageConvention, icon: "cpu",
                        color: Color.thresholdColor(
                            metrics.cpuUsage,
                            good: SystemMonitor.cpuGoodThreshold,
                            caution: SystemMonitor.cpuCautionThreshold,
                            scheme: colorScheme
                        ),
                        tooltip: "CPU used by this app across all its threads, as a percentage of everything the device can do (all cores). One fully saturated thread on a 10-core iPad is about 10%."
                    )
                    MetricGaugeView(
                        title: "Memory", value: String(format: "%.0fMB", metrics.memoryUsedMB),
                        subtitle: metrics.formattedMemory, icon: "memorychip",
                        color: Color.adaptive(.indigo, scheme: colorScheme),
                        tooltip: "Physical memory footprint of this app, shown next to the device's total RAM. They are different quantities — the app footprint is not a share of device RAM."
                    )
                }

                // MARK: — Remote Device

                dashboardSectionLabel(
                    "Remote Device",
                    icon: "ipad.rear.camera",
                    color: Color.adaptive(.purple, scheme: colorScheme)
                )

                peerInfoCard

                // MARK: — Test Suite

                testSuiteSection

                // MARK: — Log

                connectionLogSection
            }
            .padding()
        }
        .sheet(isPresented: $showAnomalies) {
            AnomalyDetailSheet(anomalies: metrics.anomalies)
        }
        .navigationTitle(peer.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Disconnect", role: .destructive) {
                    service.disconnect()
                }
            }
        }
        .onReceive(uptimeTimer) { _ in
            uptimeDisplay = metrics.formattedUptime
        }
        .alert("Info", isPresented: Binding(
            get: { activeTooltip != nil },
            set: {
                if !$0 {
                    activeTooltip = nil
                }
            }
        )) {
            Button("OK") { activeTooltip = nil }
        } message: {
            Text(activeTooltip ?? "")
        }
    }

    // MARK: - Layout helpers

    private var threeColumns: [GridItem] {
        [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
    }

    private var fourColumns: [GridItem] {
        [
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12),
        ]
    }

    private func dashboardSectionLabel(_ title: String, icon: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(title)
                .font(.title3)
                .fontWeight(.semibold)
            Spacer()
        }
        .padding(.top, 4)
    }

    // MARK: - Sections

    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    ConnectionStatusBadge(state: peer.connectionState)
                    Text("Connected to \(peer.name)")
                        .font(.headline)
                }
                HStack(spacing: 8) {
                    Text("Uptime: \(uptimeDisplay)")
                    Text("·")
                    Text(service.localRole.rawValue)
                        .fontWeight(.semibold)
                        .foregroundStyle(
                            Color.adaptive(service.localRole == .controller ? .blue : .orange, scheme: colorScheme)
                        )
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var signalQualityCard: some View {
        let quality = metrics.signalQuality
        return MetricGaugeView(
            title: "Signal Quality", value: quality.rawValue,
            subtitle: "Latency · jitter · loss", icon: "wifi",
            color: Color.gradeColor(quality.rawValue, scheme: colorScheme),
            tooltip: "Graded on the last 30 latency samples (mean and standard deviation), the current jitter, and the measured packet loss. The worst of those four decides the grade — a fast link that drops pings is not Excellent."
        )
    }

    private var latencyCard: some View {
        MetricGaugeView(
            title: "Latency", value: String(format: "%.1fms", metrics.latencyMs),
            subtitle: "Round-trip time", icon: "bolt.fill",
            color: Color.latencyColor(metrics.latencyMs, scheme: colorScheme),
            tooltip: "Round-trip time for a ping to the other device and back. Measured every 0.5s."
        )
    }

    private var connectionInfoCard: some View {
        MetricGaugeView(
            title: "Interface", value: metrics.interfaceTypeString,
            subtitle: metrics.isExpensive ? "Expensive path" : "Local network", icon: "network",
            color: Color.adaptive(.teal, scheme: colorScheme),
            tooltip: "Network interface type. 'Expensive' means cellular or hotspot."
        )
    }

    private var latencyChartSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "chart.xyaxis.line").foregroundStyle(Color.adaptive(.blue, scheme: colorScheme))
                Text("Latency Over Time").font(.headline)
                Spacer()
                Text("\(metrics.latencyHistory.count) samples").font(.caption).foregroundStyle(.secondary)
            }

            Picker("Window", selection: $latencyWindow) {
                ForEach(LatencyWindow.allCases, id: \.self) { window in
                    Text(window.label).tag(window)
                }
            }
            .pickerStyle(.segmented)

            if metrics.latencyHistory.count >= 2 {
                let windowed = latencyWindow.filter(metrics.latencyHistory)
                // Downsample for rendering, keeping the PEAK of each bucket. Plain
                // decimation would drop the spikes this chart exists to show.
                let samples = LatencyWindow.downsample(windowed, to: 400)
                let firstID = samples.first?.id ?? 0
                let maxID = samples.last?.id ?? firstID
                let domainEnd = max(maxID, firstID + 1)

                let lineColor = Color.adaptive(.blue, scheme: colorScheme)

                Chart {
                    ForEach(samples) { sample in
                        LineMark(x: .value("Sample", sample.id), y: .value("ms", sample.value))
                            .foregroundStyle(lineColor.gradient)
                            .interpolationMethod(.catmullRom)
                        AreaMark(x: .value("Sample", sample.id), y: .value("ms", sample.value))
                            .foregroundStyle(lineColor.opacity(0.1).gradient)
                            .interpolationMethod(.catmullRom)
                    }
                    // Anomaly markers — drawn from the full anomaly list so a spike is
                    // never lost to downsampling.
                    ForEach(metrics.anomalies.filter { $0.id >= firstID && $0.id <= domainEnd }) { anomaly in
                        PointMark(x: .value("Sample", anomaly.id), y: .value("ms", anomaly.value))
                            .foregroundStyle(Color.anomalyColor(anomaly.severity, scheme: colorScheme))
                            .symbolSize(anomaly.severity == .critical ? 80 : 50)
                    }
                }
                .chartXScale(domain: firstID ... domainEnd)
                .chartYAxisLabel("ms")
                .chartXAxis(.hidden)
                .frame(height: 200)

                if let first = windowed.first?.timestamp, let last = windowed.last?.timestamp {
                    HStack {
                        Text(first, style: .time)
                        Spacer()
                        Text("\(windowed.count) samples shown")
                        Spacer()
                        Text(last, style: .time)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                }

                // Anomaly count badge — tap to drill into the individual spikes
                if !metrics.anomalies.isEmpty {
                    Button {
                        showAnomalies = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(Color.anomalyColor(.warning, scheme: colorScheme))
                            let critCount = metrics.anomalies.filter { $0.severity == .critical }.count
                            let warnCount = metrics.anomalies.filter { $0.severity == .warning }.count
                            Text("\(metrics.anomalies.count) anomalies detected")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            if critCount > 0 {
                                Text("\(critCount) critical")
                                    .font(.caption2)
                                    .fontWeight(.medium)
                                    .foregroundStyle(Color.anomalyColor(.critical, scheme: colorScheme))
                            }
                            if warnCount > 0 {
                                Text("\(warnCount) warning")
                                    .font(.caption2)
                                    .fontWeight(.medium)
                                    .foregroundStyle(Color.anomalyColor(.warning, scheme: colorScheme))
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            } else {
                HStack {
                    ProgressView().scaleEffect(0.8)
                    Text("Collecting latency samples...").font(.caption).foregroundStyle(.secondary)
                }
                .frame(height: 200).frame(maxWidth: .infinity)
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var connectionHealthCard: some View {
        VStack(spacing: 12) {
            sectionHeader(
                "Connection Health",
                icon: "heart.fill",
                color: Color.adaptive(.pink, scheme: colorScheme),
                tooltip: "Disconnections count and packet loss percentage (pings unanswered for 3+ seconds). Every drop is recorded below with the reason the transport reported for it."
            )
            VStack(alignment: .leading, spacing: 6) {
                infoRow("Disconnections", "\(metrics.disconnectionCount)")
                infoRow("Packet Loss", String(format: "%.1f%%", metrics.packetLossPercent))
                infoRow("Pings Sent", "\(metrics.pingsSent)")
                infoRow("Pongs Received", "\(metrics.pongsReceived)")
            }

            Divider()
            disconnectHistorySection
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    /// Root-cause list for every drop recorded this session. Always visible so
    /// "no drops" is stated rather than left to inference from a missing card.
    private var disconnectHistorySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Disconnect Root Cause")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Spacer()
                // disconnectionCount is the authoritative total; the history
                // array itself is capped, so counting it would under-report.
                if metrics.disconnectionCount > 5 {
                    Text("last 5 of \(metrics.disconnectionCount)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            if metrics.disconnectHistory.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle")
                        .font(.caption2)
                        .foregroundStyle(Color.statusColor(true, scheme: colorScheme))
                    Text("No drops recorded this session")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                ForEach(metrics.disconnectHistory.suffix(5)) { event in
                    HStack(spacing: 6) {
                        Image(systemName: disconnectReasonIcon(event.reason))
                            .font(.caption2)
                            .foregroundStyle(disconnectReasonColor(event.reason))
                        Text(event.reason.rawValue)
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundStyle(disconnectReasonColor(event.reason))
                        if !event.detail.isEmpty {
                            Text(event.detail)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text("up \(formattedUptime(event.uptimeAtDisconnect))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(event.timestamp, style: .time)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var dataTransferCard: some View {
        VStack(spacing: 12) {
            sectionHeader(
                "Data Transfer",
                icon: "arrow.up.arrow.down",
                color: Color.adaptive(.cyan, scheme: colorScheme),
                tooltip: "Total bytes sent and received over this connection."
            )
            VStack(alignment: .leading, spacing: 6) {
                infoRow("Sent", metrics.formattedBytesSent)
                infoRow("Received", metrics.formattedBytesReceived)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var peerInfoCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            infoRow("Name", metrics.peerDeviceName ?? "Unknown")
            infoRow("Model", metrics.peerModel ?? "Unknown")
            infoRow("Model #", metrics.peerModelNumber ?? "Unknown")
            infoRow(
                "Chip",
                iPadCatalog.chipFamily(for: metrics.peerModel ?? "", modelNumber: metrics.peerModelNumber ?? "")
            )
            infoRow("OS", metrics.peerOSVersion ?? "Unknown")

            // Live responder metrics
            if let latest = metrics.remoteMetricsHistory.last {
                Divider()
                HStack(spacing: 4) {
                    Text("Live Metrics")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.caption2)
                        .foregroundStyle(Color.adaptive(.green, scheme: colorScheme))
                        .symbolEffect(.pulse)
                }
                HStack(spacing: 12) {
                    let cpuColor = Color.thresholdColor(
                        latest.cpu,
                        good: SystemMonitor.cpuGoodThreshold,
                        caution: SystemMonitor.cpuCautionThreshold,
                        scheme: colorScheme
                    )
                    let memoryColor = Color.adaptive(.indigo, scheme: colorScheme)
                    let thermalColor = Color.thermalColor(latest.thermalState, scheme: colorScheme)

                    VStack(spacing: 2) {
                        Text(String(format: "%.0f%%", latest.cpu))
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(cpuColor)
                        // Same convention as the local CPU gauge — see SystemMonitor.
                        Text("CPU (all cores)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(6)
                    .background(cpuColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))

                    VStack(spacing: 2) {
                        Text(String(format: "%.0fMB", latest.memoryMB))
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(memoryColor)
                        Text("App Memory")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(6)
                    .background(memoryColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))

                    VStack(spacing: 2) {
                        Text(latest.thermalState)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(thermalColor)
                        Text("Thermal")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(6)
                    .background(thermalColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var networkPathSection: some View {
        VStack(spacing: 12) {
            sectionHeader(
                "Network Path",
                icon: "point.3.connected.trianglepath.dotted",
                color: Color.adaptive(.teal, scheme: colorScheme),
                tooltip: "'Satisfied' = path is usable. 'Expensive' = cellular/hotspot. 'Constrained' = Low Data Mode."
            )
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                pathDetailItem(
                    "Status",
                    metrics.pathStatus == .satisfied ? "Satisfied" : "Unsatisfied",
                    Color.statusColor(metrics.pathStatus == .satisfied, scheme: colorScheme)
                )
                pathDetailItem(
                    "Expensive",
                    metrics.isExpensive ? "Yes" : "No",
                    Color.adaptive(metrics.isExpensive ? .orange : .green, scheme: colorScheme)
                )
                pathDetailItem(
                    "Constrained",
                    metrics.isConstrained ? "Yes" : "No",
                    Color.adaptive(metrics.isConstrained ? .orange : .green, scheme: colorScheme)
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var testSuiteSection: some View {
        if service.localRole == .controller {
            NavigationLink {
                TestSuiteView()
            } label: {
                HStack {
                    Image(systemName: "testtube.2").font(.title2)
                        .foregroundStyle(Color.adaptive(.blue, scheme: colorScheme))
                    VStack(alignment: .leading) {
                        Text("Run Test Suite").font(.headline)
                        // Derived, not hardcoded: the literal said 6 while the suite
                        // had grown to 7 phases.
                        Text(
                            "\(TestPhase.allCases.count) standardized tests for "
                                + "latency, throughput, jitter, stress, and more"
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                }
                .padding()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
        } else if service.localRole == .responder {
            HStack {
                Image(systemName: service.remoteTestInProgress ? "antenna.radiowaves.left.and.right" : "testtube.2")
                    .font(.title2)
                    .foregroundStyle(
                        service.remoteTestInProgress
                            ? Color.adaptive(.orange, scheme: colorScheme)
                            : Color.secondary
                    )
                    .symbolEffect(.pulse, isActive: service.remoteTestInProgress)
                VStack(alignment: .leading) {
                    Text(service.remoteTestInProgress ? "Test In Progress" : "Responder Mode").font(.headline)
                    Text(service.remoteTestInProgress
                        ? "The controller is running tests on this connection..."
                        : "Tests can only be initiated from the controller device.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()
            .background(
                service.remoteTestInProgress
                    ? Color.adaptive(.orange, scheme: colorScheme).opacity(0.05)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 12)
            )
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var connectionLogSection: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "list.bullet.rectangle").font(.title2).foregroundStyle(.gray)
                Text("Connection Log").font(.headline)
                Spacer()
                Text("\(metrics.connectionLog.count) events").font(.caption).foregroundStyle(.secondary)
            }
            if metrics.connectionLog.isEmpty {
                Text("No events yet").font(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(metrics.connectionLog) { event in
                        HStack {
                            Text(event.timestamp, style: .time).font(.caption2).foregroundStyle(.secondary)
                                .frame(width: 70, alignment: .leading)
                            Text(event.event).font(.caption)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Helpers

    @State private var activeTooltip: String?

    private func sectionHeader(_ title: String, icon: String, color: Color, tooltip: String) -> some View {
        HStack {
            Image(systemName: icon).font(.title2).foregroundStyle(color)
            Text(title).font(.headline)
            Spacer()
            Button { activeTooltip = tooltip } label: {
                Image(systemName: "info.circle").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.caption).fontWeight(.medium)
        }
    }

    private func pathDetailItem(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.subheadline).fontWeight(.semibold).foregroundStyle(color)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(8).frame(maxWidth: .infinity)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    private func disconnectReasonIcon(_ reason: DisconnectReason) -> String {
        switch reason {
        case .userInitiated: "hand.raised"
        case .remoteDisconnect: "arrow.uturn.left"
        case .keepaliveTimeout: "clock.badge.exclamationmark"
        case .pathChanged: "point.3.connected.trianglepath.dotted"
        case .tlsError: "lock.trianglebadge.exclamationmark"
        case .connectionRefused: "xmark.shield"
        case .networkError: "wifi.exclamationmark"
        case .unknown: "questionmark.circle"
        }
    }

    private func disconnectReasonColor(_ reason: DisconnectReason) -> Color {
        let base: Color = switch reason {
        case .userInitiated: .gray
        case .remoteDisconnect: .blue
        case .keepaliveTimeout: .orange
        case .pathChanged: .yellow
        case .tlsError, .connectionRefused: .red
        case .networkError: .red
        case .unknown: .gray
        }
        return Color.adaptive(base, scheme: colorScheme)
    }

    /// Compact uptime for a recorded disconnect ("2m 04s").
    private func formattedUptime(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%dh %02dm", hours, minutes)
        }
        return String(format: "%dm %02ds", minutes, seconds)
    }
}

// MARK: - Anomaly Drill-Down

/// Lists every recorded latency spike with the context captured at the time.
///
/// A count on a chart says something happened; this says what. Each row carries the
/// severity, how far above the mean the sample sat, and what the device was doing —
/// which test phase, which interface (a direct `awdl0` link behaves very differently
/// from one via an access point), CPU load and thermal state.
struct AnomalyDetailSheet: View {
    let anomalies: [LatencyAnomaly]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private var critical: [LatencyAnomaly] {
        anomalies.filter { $0.severity == .critical }
    }

    private var warnings: [LatencyAnomaly] {
        anomalies.filter { $0.severity == .warning }
    }

    var body: some View {
        NavigationStack {
            Group {
                if anomalies.isEmpty {
                    ContentUnavailableView(
                        "No anomalies",
                        systemImage: "checkmark.circle",
                        description: Text("No latency spikes beyond 3σ have been recorded on this connection.")
                    )
                } else {
                    List {
                        Section {
                            HStack(spacing: 16) {
                                countTile("Critical", critical.count, .critical)
                                countTile("Warning", warnings.count, .warning)
                            }
                            .padding(.vertical, 4)
                        } footer: {
                            Text(
                                "Critical is beyond 5σ from the rolling 30-sample mean; warning is beyond 3σ. Most recent first."
                            )
                        }

                        Section("Spikes") {
                            ForEach(anomalies.reversed()) { anomaly in
                                anomalyRow(anomaly)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Latency Anomalies")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func countTile(_ label: String, _ count: Int, _ severity: AnomalySeverity) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(count)")
                .font(.title2).fontWeight(.bold)
                .foregroundStyle(Color.anomalyColor(severity, scheme: colorScheme))
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func anomalyRow(_ anomaly: LatencyAnomaly) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: anomaly.severity == .critical
                    ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.anomalyColor(anomaly.severity, scheme: colorScheme))
                Text(String(format: "%.1f ms", anomaly.value))
                    .font(.subheadline).fontWeight(.semibold)
                    .monospacedDigit()
                Text(String(format: "%.1fσ above mean", anomaly.sigma))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(anomaly.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Text(String(format: "baseline %.1f ms · threshold %.1f ms", anomaly.mean, anomaly.threshold))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Text(anomaly.contextSummary)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Latency Chart Windowing

/// Time window for the latency chart.
///
/// The chart used to show whatever the sample buffer happened to hold, which was
/// ~60 seconds — so on a long soak the earlier history simply vanished. History is
/// now retained for an hour and this selects how much of it to display.
enum LatencyWindow: CaseIterable, Hashable {
    case oneMinute
    case fiveMinutes
    case fifteenMinutes
    case all

    var label: String {
        switch self {
        case .oneMinute: "1m"
        case .fiveMinutes: "5m"
        case .fifteenMinutes: "15m"
        case .all: "All"
        }
    }

    var seconds: TimeInterval? {
        switch self {
        case .oneMinute: 60
        case .fiveMinutes: 300
        case .fifteenMinutes: 900
        case .all: nil
        }
    }

    func filter(_ samples: [LatencySample]) -> [LatencySample] {
        guard let seconds, let last = samples.last?.timestamp else { return samples }
        let cutoff = last.addingTimeInterval(-seconds)
        return samples.filter { $0.timestamp >= cutoff }
    }

    /// Reduces `samples` to at most `limit` points, keeping the highest value in each
    /// bucket. Preserving peaks matters: a mean or a plain stride would smooth away
    /// the latency spikes the chart is there to reveal.
    static func downsample(_ samples: [LatencySample], to limit: Int) -> [LatencySample] {
        guard limit > 0, samples.count > limit else { return samples }
        let bucketSize = Int((Double(samples.count) / Double(limit)).rounded(.up))
        guard bucketSize > 1 else { return samples }

        var result: [LatencySample] = []
        result.reserveCapacity(limit + 1)
        var index = 0
        while index < samples.count {
            let end = Swift.min(index + bucketSize, samples.count)
            if let peak = samples[index ..< end].max(by: { $0.value < $1.value }) {
                result.append(peak)
            }
            index = end
        }
        return result
    }
}
