import SwiftUI

struct TestSuiteView: View {
    @Environment(BonjourService.self) private var service
    @Environment(ReportStore.self) private var reportStore
    @Environment(\.dismiss) private var dismiss
    @State private var runner: TestSuiteRunner?
    @State private var showSavedAlert = false
    @State private var config: TestSuiteConfig = .default
    @State private var showPhaseInfo: TestPhase?

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
        .sheet(item: $showPhaseInfo) { phase in
            PhaseInfoSheet(phase: phase)
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

            Text("Measures connection quality between these devices using standardized diagnostic tests.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            // Warm-up toggle
            VStack(spacing: 8) {
                HStack {
                    Image(systemName: "flame")
                        .foregroundStyle(.orange)
                    Text("Connection Warm-Up")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Spacer()
                    Toggle("", isOn: $config.runWarmUp)
                        .labelsHidden()
                }
                Text(
                    "Sends \(config.warmUpPingCount) warm-up pings before testing to settle the connection, ARP cache, and TLS session. Improves accuracy of first-phase measurements."
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))

            // Phase toggles
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Test Phases")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Spacer()
                    Text("\(config.enabledPhaseCount) of \(TestPhase.allCases.count) enabled")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 8)

                ForEach(TestPhase.allCases, id: \.rawValue) { phase in
                    phaseToggleRow(phase)
                    if phase != TestPhase.allCases.last {
                        Divider().padding(.leading, 52)
                    }
                }
                .padding(.bottom, 8)
            }
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))

            // Preset buttons
            HStack(spacing: 12) {
                Button {
                    withAnimation { config = .default }
                } label: {
                    Text("Full Suite")
                        .font(.caption)
                        .fontWeight(.medium)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    withAnimation { config = .quick }
                } label: {
                    Text("Quick Test")
                        .font(.caption)
                        .fontWeight(.medium)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            Button {
                runner.config = config
                Task { await runner.runFullSuite() }
            } label: {
                Label("Start Test Suite", systemImage: "play.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .disabled(config.enabledPhaseCount == 0)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func phaseToggleRow(_ phase: TestPhase) -> some View {
        let binding = phaseBinding(phase)
        return HStack(spacing: 10) {
            Image(systemName: phase.icon)
                .frame(width: 24)
                .foregroundStyle(binding.wrappedValue ? phaseColor(phase) : .gray)

            VStack(alignment: .leading, spacing: 2) {
                Text(phase.rawValue)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(binding.wrappedValue ? .primary : .secondary)
                Text(phase.shortDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                showPhaseInfo = phase
            } label: {
                Image(systemName: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)

            Toggle("", isOn: binding)
                .labelsHidden()
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    private func phaseBinding(_ phase: TestPhase) -> Binding<Bool> {
        switch phase {
        case .latencyBurst: $config.runLatencyBurst
        case .sustainedThroughput: $config.runThroughput
        case .jitterMeasurement: $config.runJitter
        case .packetLossStress: $config.runPacketLoss
        case .latencyUnderLoad: $config.runLatencyUnderLoad
        case .heavyLoad: $config.runHeavyLoad
        }
    }

    private func runningView(_ runner: TestSuiteRunner) -> some View {
        VStack(spacing: 16) {
            // Warm-up indicator
            if runner.isWarmingUp {
                HStack(spacing: 12) {
                    ProgressView()
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Warming Up Connection")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text("Settling connection, ARP cache, and TLS session...")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding()
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }

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

            // Phase cards (only show enabled phases)
            ForEach(TestPhase.allCases, id: \.rawValue) { phase in
                let status = runner.phaseStatuses[phase] ?? .pending
                if status != .skipped {
                    phaseCard(phase, runner: runner)
                }
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
                case .skipped:
                    Image(systemName: "forward.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                    .foregroundStyle(status == .pending || status == .skipped ? .secondary : .primary)

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
                    Text(phase.shortDescription)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                case .skipped:
                    Text("Skipped")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                        // Auto-sync to the connected peer
                        if let data = reportStore.encodeForSync(report) {
                            service.sendReport(data)
                        }
                        showSavedAlert = true
                    }
                } label: {
                    Label("Save & Sync", systemImage: "square.and.arrow.down")
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
                resultRow("Impact", report.results.latencyUnderLoad.formattedDegradation)
            }

            testResultCard("System Metrics (Controller)", icon: "cpu", color: .indigo) {
                let s = report.results.systemMetrics
                resultRow("Battery Drain", String(format: "%.2f%%", s.batteryDrainPercent))
                resultRow("Peak CPU", String(format: "%.1f%%", s.peakCpuUsage))
                resultRow("Avg CPU", String(format: "%.1f%%", s.avgCpuUsage))
                resultRow("Peak Memory", String(format: "%.0f MB", s.peakMemoryMB))
                resultRow("Thermal", s.thermalStateDuringTest)
            }

            if let r = report.results.responderMetrics {
                testResultCard("System Metrics (Responder)", icon: "cpu", color: .teal) {
                    resultRow("Battery Drain", String(format: "%.2f%%", r.batteryDrainPercent))
                    resultRow("Peak CPU", String(format: "%.1f%%", r.peakCpuUsage))
                    resultRow("Avg CPU", String(format: "%.1f%%", r.avgCpuUsage))
                    resultRow("Peak Memory", String(format: "%.0f MB", r.peakMemoryMB))
                    resultRow("Thermal", r.thermalStateDuringTest)
                }
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
        case .latencyBurst: "\(config.latencyBurstCount) pings"
        case .sustainedThroughput: formatBytes(config.throughputBytes)
        case .jitterMeasurement: "\(config.jitterSampleCount) samples"
        case .packetLossStress: "\(config.packetLossCount) pings"
        case .latencyUnderLoad: "~10s"
        case .heavyLoad: "~15s"
        }
    }

    private func statusBackground(_ status: PhaseStatus, isActive _: Bool) -> Color {
        switch status {
        case .pending: .gray.opacity(0.2)
        case .running: .blue.opacity(0.2)
        case .completed: .green
        case .skipped: .gray.opacity(0.3)
        case .failed: .red
        }
    }

    private func deviceInfoColumn(_ label: String, _ info: DeviceInfo) -> some View {
        VStack(spacing: 4) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(info.name).font(.subheadline).fontWeight(.medium)
            Text(info.displayModel).font(.caption).foregroundStyle(.secondary)
            if !info.modelNumber.isEmpty {
                Text(info.modelNumber).font(.caption2).foregroundStyle(.tertiary)
            }
            Text(info.osVersion).font(.caption2).foregroundStyle(.tertiary)
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

// MARK: - Phase Info Sheet

extension TestPhase: Identifiable {
    var id: String {
        rawValue
    }
}

struct PhaseInfoSheet: View {
    let phase: TestPhase
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Header
                    HStack(spacing: 14) {
                        ZStack {
                            Circle()
                                .fill(phaseColor.opacity(0.15))
                                .frame(width: 56, height: 56)
                            Image(systemName: phase.icon)
                                .font(.title2)
                                .foregroundStyle(phaseColor)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(phase.rawValue)
                                .font(.title2)
                                .fontWeight(.bold)
                            Text(phase.shortDescription)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // What it does
                    VStack(alignment: .leading, spacing: 8) {
                        Label("What it does", systemImage: "gear")
                            .font(.headline)
                        Text(phase.detailedDescription)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    // Why it matters
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Why it matters", systemImage: "lightbulb")
                            .font(.headline)
                        Text(phase.whyItMatters)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    // Technical details
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Parameters", systemImage: "slider.horizontal.3")
                            .font(.headline)
                        parametersView
                    }
                }
                .padding()
            }
            .navigationTitle("Test Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var parametersView: some View {
        let config = TestSuiteConfig.default
        VStack(spacing: 6) {
            switch phase {
            case .latencyBurst:
                paramRow("Ping count", "\(config.latencyBurstCount)")
                paramRow("Interval", "\(config.latencyBurstIntervalMs) ms")
                paramRow("Wait for responses", "2 s")
                paramRow("Measures", "Min, Max, Avg, Median, P95 RTT")
            case .sustainedThroughput:
                paramRow("Data size", "\(config.throughputBytes / 1_000_000) MB")
                paramRow("Chunk size", "32 KB")
                paramRow("Measures", "Bytes/sec, total time")
            case .jitterMeasurement:
                paramRow("Sample count", "\(config.jitterSampleCount)")
                paramRow("Interval", "\(config.jitterIntervalMs) ms")
                paramRow("Wait for responses", "2 s")
                paramRow("Measures", "Avg jitter, Max jitter (ms between consecutive samples)")
            case .packetLossStress:
                paramRow("Ping count", "\(config.packetLossCount)")
                paramRow("Interval", "\(config.packetLossIntervalMs) ms")
                paramRow("Wait for responses", "3 s")
                paramRow("Measures", "Sent, Received, Loss %")
            case .latencyUnderLoad:
                paramRow("Load chunks", "800")
                paramRow("Latency probes", "50")
                paramRow("Probe interval", "200 ms")
                paramRow("Measures", "Baseline vs under-load avg, degradation %")
            case .heavyLoad:
                paramRow("Concurrent load streams", "3")
                paramRow("Duration", "~15 s")
                paramRow("Latency probes", "75")
                paramRow("Measures", "Avg/Max latency, throughput, packet loss under max stress")
            }
        }
    }

    private func paramRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
    }

    private var phaseColor: Color {
        switch phase.color {
        case "blue": .blue
        case "purple": .purple
        case "orange": .orange
        case "red": .red
        default: .blue
        }
    }
}
