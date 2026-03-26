import Charts
import SwiftUI

struct DiagnosticDashboardView: View {
    let peer: PeerDevice
    @Environment(BonjourService.self) private var service
    @State private var uptimeTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var uptimeDisplay: String = "0m 00s"

    private var metrics: DiagnosticMetrics {
        peer.metrics
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                headerSection

                // Top metric cards
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12),
                ], spacing: 12) {
                    signalQualityCard
                    latencyCard
                    connectionInfoCard
                }

                // Latency chart
                latencyChartSection

                // Latency stats + packet loss + jitter
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12),
                ], spacing: 12) {
                    MetricGaugeView(
                        title: "Min Latency",
                        value: String(format: "%.1fms", metrics.latencyMin),
                        subtitle: "All-time low",
                        icon: "arrow.down",
                        color: .green,
                        tooltip: "The lowest round-trip latency recorded during this session. Represents the best-case connection speed between the two devices."
                    )
                    MetricGaugeView(
                        title: "Max Latency",
                        value: String(format: "%.1fms", metrics.latencyMax),
                        subtitle: "All-time high",
                        icon: "arrow.up",
                        color: .red,
                        tooltip: "The highest round-trip latency recorded during this session. Spikes can indicate network congestion, interference, or the device briefly switching network paths."
                    )
                    MetricGaugeView(
                        title: "Avg Latency",
                        value: String(format: "%.1fms", metrics.latencyAvg),
                        subtitle: "Overall average",
                        icon: "equal",
                        color: .blue,
                        tooltip: "The mean round-trip latency across all samples in this session. A good overall indicator of connection quality."
                    )
                    MetricGaugeView(
                        title: "Jitter",
                        value: String(format: "%.1fms", metrics.jitterMs),
                        subtitle: "Latency variation",
                        icon: "waveform.path",
                        color: metrics.jitterMs < 5 ? .green :
                            metrics.jitterMs < 15 ? .orange : .red,
                        tooltip: "The average difference between consecutive latency measurements. Low jitter (<5ms) means a stable connection. High jitter indicates inconsistent network performance, which can cause issues with real-time communication."
                    )
                }

                // System metrics
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12),
                ], spacing: 12) {
                    MetricGaugeView(
                        title: "Battery",
                        value: metrics.batteryPercent,
                        subtitle: "Drain: \(metrics.batteryDrain)",
                        icon: "battery.75percent",
                        color: metrics.batteryLevel > 0.5 ? .green :
                            metrics.batteryLevel > 0.2 ? .orange : .red,
                        tooltip: "Current battery level and total drain since this connection started. Useful for measuring how much power the Bonjour connection consumes over time."
                    )
                    MetricGaugeView(
                        title: "Thermal",
                        value: metrics.thermalState,
                        subtitle: metrics.batteryState,
                        icon: "thermometer.medium",
                        color: metrics.thermalState == "Nominal" ? .green :
                            metrics.thermalState == "Fair" ? .yellow :
                            metrics.thermalState == "Serious" ? .orange : .red,
                        tooltip: "Device thermal state from the system. Nominal is ideal. Fair means slightly warm. Serious/Critical may cause the system to throttle performance, affecting connection quality."
                    )
                    MetricGaugeView(
                        title: "CPU",
                        value: String(format: "%.0f%%", metrics.cpuUsage),
                        subtitle: "App usage",
                        icon: "cpu",
                        color: metrics.cpuUsage < 30 ? .green :
                            metrics.cpuUsage < 60 ? .orange : .red,
                        tooltip: "CPU usage by this app across all threads. High CPU usage may indicate the connection is putting significant load on the device, which can affect battery life and thermal state."
                    )
                    MetricGaugeView(
                        title: "Memory",
                        value: String(format: "%.0fMB", metrics.memoryUsedMB),
                        subtitle: metrics.formattedMemory,
                        icon: "memorychip",
                        color: .indigo,
                        tooltip: "Physical memory used by this app. Shows current usage and total device memory."
                    )
                }

                // Throughput + peer info
                HStack(spacing: 12) {
                    ThroughputTestView(metrics: metrics) {
                        service.engine?.runThroughputTest()
                    }
                    peerInfoCard
                }

                // Connection health + data transfer
                HStack(spacing: 12) {
                    connectionHealthCard
                    dataTransferCard
                }

                // Network path details
                networkPathSection

                // Test Suite / Role
                if service.localRole == .controller {
                    NavigationLink {
                        TestSuiteView()
                    } label: {
                        HStack {
                            Image(systemName: "testtube.2")
                                .font(.title2)
                                .foregroundStyle(.blue)
                            VStack(alignment: .leading) {
                                Text("Run Test Suite")
                                    .font(.headline)
                                Text("6 standardized tests for latency, throughput, jitter, stress, and more")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.secondary)
                        }
                        .padding()
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                } else if service.localRole == .responder {
                    HStack {
                        Image(systemName: service
                            .remoteTestInProgress ? "antenna.radiowaves.left.and.right" : "testtube.2")
                            .font(.title2)
                            .foregroundStyle(service.remoteTestInProgress ? .orange : .secondary)
                            .symbolEffect(.pulse, isActive: service.remoteTestInProgress)
                        VStack(alignment: .leading) {
                            Text(service.remoteTestInProgress ? "Test In Progress" : "Responder Mode")
                                .font(.headline)
                            Text(service.remoteTestInProgress
                                ? "The controller is running tests on this connection..."
                                : "Tests can only be initiated from the controller device.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding()
                    .background(
                        service.remoteTestInProgress ? Color.orange.opacity(0.05) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }

                // Connection log
                connectionLogSection
            }
            .padding()
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
            set: { if !$0 { activeTooltip = nil } }
        )) {
            Button("OK") { activeTooltip = nil }
        } message: {
            Text(activeTooltip ?? "")
        }
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
                        .foregroundStyle(service.localRole == .controller ? .blue : .orange)
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
        let color: Color = switch quality {
        case .excellent: .green
        case .good: .blue
        case .fair: .orange
        case .poor: .red
        }

        return MetricGaugeView(
            title: "Signal Quality",
            value: quality.rawValue,
            subtitle: "Based on latency stability",
            icon: "wifi",
            color: color,
            tooltip: "Derived from the mean and standard deviation of the last 30 latency samples. Excellent: <10ms avg, <3ms stddev. Good: <30ms, <10ms. Fair: <100ms, <30ms. Poor: above these thresholds."
        )
    }

    private var latencyCard: some View {
        MetricGaugeView(
            title: "Latency",
            value: String(format: "%.1fms", metrics.latencyMs),
            subtitle: "Round-trip time",
            icon: "bolt.fill",
            color: metrics.latencyMs < 10 ? .green :
                metrics.latencyMs < 30 ? .blue :
                metrics.latencyMs < 100 ? .orange : .red,
            tooltip: "The time in milliseconds for a ping message to travel to the other device and back. Measured every 0.5 seconds. Lower is better. Green: <10ms, Blue: <30ms, Orange: <100ms, Red: >100ms."
        )
    }

    private var connectionInfoCard: some View {
        MetricGaugeView(
            title: "Interface",
            value: metrics.interfaceTypeString,
            subtitle: metrics.isExpensive ? "Expensive path" : "Local network",
            icon: "network",
            color: .teal,
            tooltip: "The network interface used for this connection. Wi-Fi means a shared wireless network. 'Expensive' indicates a cellular or hotspot connection that may incur data charges."
        )
    }

    private var latencyChartSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "chart.xyaxis.line")
                    .foregroundStyle(.blue)
                Text("Latency Over Time")
                    .font(.headline)
                Spacer()
                Text("\(metrics.latencyHistory.count) samples")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if metrics.latencyHistory.count >= 2 {
                let samples = metrics.latencyHistory
                let maxID = samples.last!.id
                let windowSize = max(maxID - samples.first!.id, 60)

                Chart(samples) { sample in
                    LineMark(
                        x: .value("Sample", sample.id),
                        y: .value("Latency (ms)", sample.value)
                    )
                    .foregroundStyle(.blue.gradient)
                    .interpolationMethod(.catmullRom)

                    AreaMark(
                        x: .value("Sample", sample.id),
                        y: .value("Latency (ms)", sample.value)
                    )
                    .foregroundStyle(.blue.opacity(0.1).gradient)
                    .interpolationMethod(.catmullRom)
                }
                .chartXScale(domain: (maxID - windowSize) ... maxID)
                .chartYAxisLabel("ms")
                .chartXAxis(.hidden)
                .frame(height: 200)
            } else {
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Collecting latency samples...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(height: 200)
                .frame(maxWidth: .infinity)
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
                color: .pink,
                tooltip: "Tracks connection reliability. Disconnections count how many times the link dropped. Packet loss shows the percentage of pings that went unanswered for 3+ seconds."
            )

            VStack(alignment: .leading, spacing: 6) {
                infoRow("Disconnections", "\(metrics.disconnectionCount)")
                infoRow("Packet Loss", String(format: "%.1f%%", metrics.packetLossPercent))
                infoRow("Pings Sent", "\(metrics.pingsSent)")
                infoRow("Pongs Received", "\(metrics.pongsReceived)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var dataTransferCard: some View {
        VStack(spacing: 12) {
            sectionHeader(
                "Data Transfer",
                icon: "arrow.up.arrow.down",
                color: .cyan,
                tooltip: "Total bytes sent and received over this connection, including ping/pong messages and throughput test data."
            )

            VStack(alignment: .leading, spacing: 6) {
                infoRow("Sent", metrics.formattedBytesSent)
                infoRow("Received", metrics.formattedBytesReceived)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var peerInfoCard: some View {
        VStack(spacing: 12) {
            sectionHeader(
                "Peer Device",
                icon: "ipad",
                color: .indigo,
                tooltip: "Information about the connected device, exchanged automatically when the connection is established."
            )

            VStack(alignment: .leading, spacing: 6) {
                infoRow("Name", metrics.peerDeviceName ?? "Unknown")
                infoRow("Model", metrics.peerModel ?? "Unknown")
                infoRow("OS", metrics.peerOSVersion ?? "Unknown")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var networkPathSection: some View {
        VStack(spacing: 12) {
            sectionHeader(
                "Network Path Details",
                icon: "point.3.connected.trianglepath.dotted",
                color: .teal,
                tooltip: "Low-level network path information from Apple's Network framework. 'Satisfied' means the path is usable. 'Expensive' indicates cellular or personal hotspot. 'Constrained' means Low Data Mode is active."
            )

            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible()),
            ], spacing: 8) {
                pathDetailItem(
                    "Path Status",
                    metrics.pathStatus == .satisfied ? "Satisfied" : "Unsatisfied",
                    metrics.pathStatus == .satisfied ? .green : .red
                )
                pathDetailItem(
                    "Expensive",
                    metrics.isExpensive ? "Yes" : "No",
                    metrics.isExpensive ? .orange : .green
                )
                pathDetailItem(
                    "Constrained",
                    metrics.isConstrained ? "Yes" : "No",
                    metrics.isConstrained ? .orange : .green
                )
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var connectionLogSection: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "list.bullet.rectangle")
                    .font(.title2)
                    .foregroundStyle(.gray)
                Text("Connection Log")
                    .font(.headline)
                Spacer()
                Text("\(metrics.connectionLog.count) events")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if metrics.connectionLog.isEmpty {
                Text("No events yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(metrics.connectionLog) { event in
                        HStack {
                            Text(event.timestamp, style: .time)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .frame(width: 70, alignment: .leading)
                            Text(event.event)
                                .font(.caption)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Helpers

    @State private var activeTooltip: String?

    private func sectionHeader(_ title: String, icon: String, color: Color, tooltip: String) -> some View {
        HStack {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
            Text(title)
                .font(.headline)
            Spacer()
            Button {
                activeTooltip = tooltip
            } label: {
                Image(systemName: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption)
                .fontWeight(.medium)
        }
    }

    private func pathDetailItem(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}
