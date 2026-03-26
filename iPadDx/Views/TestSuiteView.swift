import SwiftUI

struct TestSuiteView: View {
    @Environment(BonjourService.self) private var service
    @Environment(ReportStore.self) private var reportStore
    @Environment(\.dismiss) private var dismiss
    @State private var runner: TestSuiteRunner?
    @State private var showSavedAlert = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let runner {
                    switch runner.state {
                    case .idle:
                        idleCard(runner)
                    case .running:
                        runningView(runner)
                    case .completed:
                        completedHeader(runner)
                        if let report = runner.lastReport {
                            resultsSection(report)
                        }
                    case let .failed(error):
                        failedCard(error, runner: runner)
                    }
                } else {
                    notConnectedCard
                }
            }
            .padding()
        }
        .navigationTitle("Test Suite")
        .onAppear {
            if runner == nil, let engine = service.engine,
               let cm = service.activeConnectionManager
            {
                let r = TestSuiteRunner(connectionManager: cm, metrics: engine.metrics)
                engine.testSuiteRunner = r
                runner = r
            }
        }
        .alert("Report Saved", isPresented: $showSavedAlert) {
            Button("Back to Dashboard") { dismiss() }
            Button("Stay Here") {}
        } message: {
            Text("View and compare reports from the Saved Reports section in the sidebar.")
        }
    }

    // MARK: - State Cards

    private func idleCard(_ runner: TestSuiteRunner) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "testtube.2")
                .font(.system(size: 50))
                .foregroundStyle(.blue)

            Text("Connection Test Suite")
                .font(.title2)
                .fontWeight(.bold)

            Text("Run 6 standardized tests to thoroughly measure connection quality between these devices.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(TestPhase.allCases, id: \.rawValue) { phase in
                    HStack(spacing: 10) {
                        Image(systemName: phase.icon)
                            .frame(width: 20)
                            .foregroundStyle(phaseColor(phase))
                        Text(phase.rawValue)
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Spacer()
                        Text(phaseDetail(phase))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))

            Button {
                Task { await runner.runFullSuite() }
            } label: {
                Label("Start Test Suite", systemImage: "play.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func runningView(_ runner: TestSuiteRunner) -> some View {
        VStack(spacing: 16) {
            // Overall progress
            VStack(spacing: 8) {
                ProgressView(value: runner.progress) {
                    HStack {
                        Text("Overall Progress")
                            .font(.headline)
                        Spacer()
                        Text("\(Int(runner.progress * 100))%")
                            .font(.headline)
                            .foregroundStyle(.blue)
                    }
                }
                .tint(.blue)
            }
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))

            // Phase cards
            ForEach(TestPhase.allCases, id: \.rawValue) { phase in
                phaseCard(phase, runner: runner)
            }
        }
    }

    private func phaseCard(_ phase: TestPhase, runner: TestSuiteRunner) -> some View {
        let status = runner.phaseStatuses[phase] ?? .pending
        let isActive = runner.currentPhase == phase

        return HStack(spacing: 12) {
            // Status icon
            ZStack {
                Circle()
                    .fill(statusBackground(status, isActive: isActive))
                    .frame(width: 36, height: 36)

                switch status {
                case .pending:
                    Image(systemName: phase.icon)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .running:
                    ProgressView()
                        .scaleEffect(0.7)
                case .completed:
                    Image(systemName: "checkmark")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                case .failed:
                    Image(systemName: "xmark")
                        .font(.caption)
                        .foregroundStyle(.white)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(phase.rawValue)
                    .font(.subheadline)
                    .fontWeight(isActive ? .bold : .medium)
                    .foregroundStyle(status == .pending ? .secondary : .primary)

                switch status {
                case .running:
                    ProgressView(value: runner.phaseProgress)
                        .tint(phaseColor(phase))
                    if runner.livePingCount > 0 {
                        Text("Ping #\(runner.livePingCount) — \(String(format: "%.1fms", runner.liveLatency))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                case let .completed(summary):
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.green)
                case .pending:
                    Text(phase.description)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                case .failed:
                    Text("Failed")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Spacer()
        }
        .padding()
        .background(isActive ? phaseColor(phase).opacity(0.05) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .animation(.easeInOut(duration: 0.3), value: status)
    }

    private func completedHeader(_ runner: TestSuiteRunner) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 50))
                .foregroundStyle(.green)

            Text("Test Suite Complete")
                .font(.title2)
                .fontWeight(.bold)

            if let report = runner.lastReport {
                Text(String(format: "%.1f seconds | Grade: %@", report.durationSeconds, report.results.overallGrade))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button {
                    if let report = runner.lastReport {
                        reportStore.save(report)
                        showSavedAlert = true
                    }
                } label: {
                    Label("Save Report", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    runner.reset()
                } label: {
                    Label("Run Again", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func failedCard(_ error: String, runner: TestSuiteRunner) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.red)
            Text("Test Failed")
                .font(.headline)
            Text(error)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Retry") { runner.reset() }
                .buttonStyle(.bordered)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var notConnectedCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Not connected to a peer device.")
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Results

    private func resultsSection(_ report: TestReport) -> some View {
        VStack(spacing: 12) {
            HStack {
                Text("Overall Grade:")
                    .font(.headline)
                Text(report.results.overallGrade)
                    .font(.title)
                    .fontWeight(.bold)
                    .foregroundStyle(gradeColor(report.results.overallGrade))
                Spacer()
            }
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))

            // Device pair
            HStack {
                deviceInfoColumn("Local", report.localDevice)
                Spacer()
                Image(systemName: "arrow.left.arrow.right").foregroundStyle(.secondary)
                Spacer()
                deviceInfoColumn("Remote", report.remoteDevice)
            }
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))

            testResultCard("Latency Burst", icon: "bolt.fill", color: .blue) {
                let l = report.results.latencyBurst
                resultRow("Min", String(format: "%.2fms", l.min))
                resultRow("Max", String(format: "%.2fms", l.max))
                resultRow("Avg", String(format: "%.2fms", l.avg))
                resultRow("Median", String(format: "%.2fms", l.median))
                resultRow("P95", String(format: "%.2fms", l.p95))
                resultRow("Samples", "\(l.sampleCount)")
            }

            testResultCard("Throughput", icon: "arrow.up.arrow.down.circle.fill", color: .purple) {
                resultRow("Speed", report.results.sustainedThroughput.formattedSpeed)
                resultRow("Data Sent", formatBytes(report.results.sustainedThroughput.totalBytes))
                resultRow("Duration", String(format: "%.2fs", report.results.sustainedThroughput.durationSeconds))
            }

            testResultCard("Jitter", icon: "waveform.path", color: .orange) {
                resultRow("Average", String(format: "%.2fms", report.results.jitterMeasurement.averageJitter))
                resultRow("Max", String(format: "%.2fms", report.results.jitterMeasurement.maxJitter))
                resultRow("Samples", "\(report.results.jitterMeasurement.sampleCount)")
            }

            testResultCard("Packet Loss Stress", icon: "exclamationmark.triangle.fill", color: .red) {
                resultRow("Sent", "\(report.results.packetLossStress.sent)")
                resultRow("Received", "\(report.results.packetLossStress.received)")
                resultRow("Loss", String(format: "%.1f%%", report.results.packetLossStress.lostPercent))
            }

            testResultCard("Latency Under Load", icon: "flame.fill", color: .orange) {
                resultRow("Baseline", String(format: "%.2fms", report.results.latencyUnderLoad.baselineAvg))
                resultRow("Under Load", String(format: "%.2fms", report.results.latencyUnderLoad.underLoadAvg))
                resultRow("Degradation", String(format: "%.1f%%", report.results.latencyUnderLoad.degradationPercent))
            }

            testResultCard("System Metrics", icon: "cpu", color: .indigo) {
                let s = report.results.systemMetrics
                resultRow("Battery Drain", String(format: "%.2f%%", s.batteryDrainPercent))
                resultRow("Peak CPU", String(format: "%.1f%%", s.peakCpuUsage))
                resultRow("Avg CPU", String(format: "%.1f%%", s.avgCpuUsage))
                resultRow("Peak Memory", String(format: "%.0f MB", s.peakMemoryMB))
                resultRow("Thermal", s.thermalStateDuringTest)
            }
        }
    }

    // MARK: - Helpers

    private func phaseColor(_ phase: TestPhase) -> Color {
        switch phase.color {
        case "blue": .blue
        case "purple": .purple
        case "orange": .orange
        case "red": .red
        default: .blue
        }
    }

    private func phaseDetail(_ phase: TestPhase) -> String {
        switch phase {
        case .latencyBurst: "100 pings"
        case .sustainedThroughput: "10 MB"
        case .jitterMeasurement: "150 samples"
        case .packetLossStress: "500 pings"
        case .latencyUnderLoad: "~10s"
        case .heavyLoad: "~15s"
        }
    }

    private func statusBackground(_ status: PhaseStatus, isActive _: Bool) -> Color {
        switch status {
        case .pending: .gray.opacity(0.2)
        case .running: .blue.opacity(0.2)
        case .completed: .green
        case .failed: .red
        }
    }

    private func deviceInfoColumn(_ label: String, _ info: DeviceInfo) -> some View {
        VStack(spacing: 4) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(info.name).font(.subheadline).fontWeight(.medium)
            Text(info.model).font(.caption).foregroundStyle(.secondary)
            Text(info.chipFamily).font(.caption).fontWeight(.semibold).foregroundStyle(.blue)
        }
    }

    private func testResultCard(
        _ title: String,
        icon: String,
        color: Color,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(spacing: 8) {
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

    private func resultRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.caption).fontWeight(.medium)
        }
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
