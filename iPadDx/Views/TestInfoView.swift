import SwiftUI

struct TestInfoView: View {
    @State private var expandedPhase: TestPhase?

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Header
                VStack(spacing: 8) {
                    Image(systemName: "testtube.2")
                        .font(.system(size: 50))
                        .foregroundStyle(.blue)
                    Text("Connection Test Suite")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text(
                        "6 standardized diagnostic tests that measure the quality and reliability of the Bonjour connection between two iPads. Works over a shared Wi-Fi network or peer-to-peer without an access point."
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))

                // How it works
                VStack(alignment: .leading, spacing: 12) {
                    Label("How It Works", systemImage: "gearshape.2")
                        .font(.headline)

                    step(
                        number: 1,
                        text: "Connect two iPads via Bonjour — works over shared Wi-Fi or peer-to-peer (no access point needed)"
                    )
                    step(number: 2, text: "An optional warm-up phase settles the connection (ARP cache, TLS session)")
                    step(
                        number: 3,
                        text: "6 test phases run sequentially, each measuring a different aspect of connection quality"
                    )
                    step(
                        number: 4,
                        text: "Results are graded Excellent / Good / Fair / Poor based on a composite score"
                    )
                    step(number: 5, text: "Reports are saved and can be compared across device pairs and sessions")
                }
                .padding()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))

                // Test phases
                VStack(alignment: .leading, spacing: 4) {
                    Label("Test Phases", systemImage: "list.number")
                        .font(.headline)
                        .padding(.horizontal)
                        .padding(.top, 12)

                    ForEach(TestPhase.allCases, id: \.rawValue) { phase in
                        phaseRow(phase)
                    }
                    .padding(.bottom, 8)
                }
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))

                // Grading
                gradingSection

                // Warm-up
                warmUpSection
            }
            .padding()
        }
        .navigationTitle("Test Suite Info")
    }

    // MARK: - Phase Row

    private func phaseRow(_ phase: TestPhase) -> some View {
        let isExpanded = expandedPhase == phase
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    expandedPhase = isExpanded ? nil : phase
                }
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(phaseColor(phase).opacity(0.15))
                            .frame(width: 40, height: 40)
                        Image(systemName: phase.icon)
                            .foregroundStyle(phaseColor(phase))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(phase.rawValue)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(.primary)
                        Text(phase.shortDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("What it does")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.blue)
                        Text(phase.detailedDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Why it matters")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.orange)
                        Text(phase.whyItMatters)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Parameters")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.purple)
                        parametersGrid(phase)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.leading, 36)
                .padding(.bottom, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    @ViewBuilder
    private func parametersGrid(_ phase: TestPhase) -> some View {
        let cfg = TestSuiteConfig.default
        VStack(spacing: 4) {
            switch phase {
            case .latencyBurst:
                paramRow("Ping count", "\(cfg.latencyBurstCount)")
                paramRow("Interval", "\(cfg.latencyBurstIntervalMs) ms between pings")
                paramRow("Wait", "2 s for final responses")
                paramRow("Output", "Min, Max, Avg, Median, P95 RTT")
            case .sustainedThroughput:
                paramRow("Data size", "\(cfg.throughputBytes / 1_000_000) MB")
                paramRow("Chunk size", "32 KB per message")
                paramRow("Output", "MB/s, total time")
            case .jitterMeasurement:
                paramRow("Samples", "\(cfg.jitterSampleCount)")
                paramRow("Interval", "\(cfg.jitterIntervalMs) ms between pings")
                paramRow("Wait", "2 s for final responses")
                paramRow("Output", "Avg jitter, Max jitter (ms)")
            case .packetLossStress:
                paramRow("Ping count", "\(cfg.packetLossCount)")
                paramRow("Interval", "\(cfg.packetLossIntervalMs) ms (aggressive)")
                paramRow("Wait", "3 s for final responses")
                paramRow("Output", "Sent, Received, Loss %")
            case .latencyUnderLoad:
                paramRow("Load", "800 data chunks at 12 ms")
                paramRow("Probes", "50 latency pings at 200 ms")
                paramRow("Output", "Baseline avg, Under-load avg, Degradation %")
            case .heavyLoad:
                paramRow("Load streams", "3 concurrent generators")
                paramRow("Duration", "~15 seconds")
                paramRow("Probes", "75 latency pings at 200 ms")
                paramRow("Output", "Avg/Max latency, throughput, packet loss")
            }
        }
    }

    private func paramRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: - Grading

    private var gradingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Grading Algorithm", systemImage: "star.leadinghalf.filled")
                .font(.headline)

            Text("Each test contributes 0–3 points to a composite score (max 12). The grade is based on the total:")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(spacing: 6) {
                gradeRow("Excellent", "9–12 points", .green)
                gradeRow("Good", "6–8 points", .blue)
                gradeRow("Fair", "3–5 points", .orange)
                gradeRow("Poor", "0–2 points", .red)
            }

            Divider()

            Text("Scoring criteria:")
                .font(.caption)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 8) {
                criteriaGroup("Latency", [
                    ("3 pts", "< 10 ms avg"),
                    ("2 pts", "< 30 ms avg"),
                    ("1 pt", "< 100 ms avg"),
                ])
                criteriaGroup("Jitter", [
                    ("3 pts", "< 5 ms avg"),
                    ("2 pts", "< 15 ms avg"),
                    ("1 pt", "< 30 ms avg"),
                ])
                criteriaGroup("Packet Loss", [
                    ("3 pts", "< 1% loss"),
                    ("2 pts", "< 5% loss"),
                    ("1 pt", "< 10% loss"),
                ])
                criteriaGroup("Load Degradation", [
                    ("3 pts", "0% or improved"),
                    ("2 pts", "< 50% worse"),
                    ("1 pt", "< 100% worse"),
                ])
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func gradeRow(_ grade: String, _ range: String, _ color: Color) -> some View {
        HStack {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(grade).font(.caption).fontWeight(.semibold)
            Spacer()
            Text(range).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private func criteriaGroup(_ title: String, _ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundStyle(.blue)
            ForEach(rows, id: \.0) { pts, desc in
                HStack {
                    Text(pts)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .leading)
                    Text(desc)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Warm-Up

    private var warmUpSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Connection Warm-Up", systemImage: "flame")
                .font(.headline)

            Text(
                "Before running tests, an optional warm-up phase sends 10 pings to settle the connection. This ensures:"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                bulletPoint("Wireless radio is active and tuned to the right channel")
                bulletPoint("ARP cache has resolved the peer's MAC address")
                bulletPoint("TLS-PSK session is fully established")
                bulletPoint("Network.framework's internal buffers are primed")
            }

            Text(
                "Without warm-up, the first test phase can show ~60% higher latency than subsequent phases, skewing results."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .italic()
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func bulletPoint(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•").font(.caption).foregroundStyle(.secondary)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

    private func step(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(.blue, in: Circle())
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func phaseColor(_ phase: TestPhase) -> Color {
        switch phase.color {
        case "blue": .blue
        case "purple": .purple
        case "orange": .orange
        case "red": .red
        default: .blue
        }
    }
}
