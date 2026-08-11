import SwiftUI

struct BridgeInfoView: View {
    @Environment(ReportStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme
    @State private var expandedBridge: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Header
                VStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 50))
                        .foregroundStyle(Color.adaptive(.purple, scheme: colorScheme))
                    Text("Bridge Transports")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text(
                        "Real framework runtimes that add overhead to every message. Tests run through the same bridge the target app uses, measuring what users actually experience."
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))

                // Bridge status
                bridgeStatusSection

                // Bridge details
                VStack(alignment: .leading, spacing: 4) {
                    Label("Bridge Details", systemImage: "cpu")
                        .font(.headline)
                        .padding(.horizontal)
                        .padding(.top, 12)

                    ForEach(bridges, id: \.id) { bridge in
                        bridgeRow(bridge)
                    }
                    .padding(.bottom, 8)
                }
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))

                // How it works
                howItWorksSection

                // Overhead comparison
                overheadSection
            }
            .padding()
        }
        .navigationTitle("Bridge Transport Info")
    }

    // MARK: - Bridge Data

    private struct BridgeDetail: Identifiable {
        let id: String
        let name: String
        let icon: String
        let technology: String
        let processBoundary: String
        let serialization: String
        let binaryData: String
        let dominantOverhead: String
        let description: String
        let dataPath: String
    }

    private var bridges: [BridgeDetail] {
        [
            BridgeDetail(
                id: "native",
                name: "Native (Baseline)",
                icon: "network",
                technology: "Network.framework direct",
                processBoundary: "None",
                serialization: "None — raw bytes on the wire",
                binaryData: "Raw Data (zero-copy)",
                dominantOverhead: "Network latency only — no framework overhead",
                description: "Direct Swift on Apple's Network.framework with TLS-PSK encryption. Messages are length-prefixed (4-byte big-endian header) and sent over TCP with keepalive enabled (10s idle, 5s retry, 3 missed = disconnect). Nagle's algorithm is disabled for low-latency pings. This is the baseline that all other bridges are compared against — any overhead measured by other bridges is purely from the framework runtime.",
                dataPath: "Swift send(Data) -> 4-byte length prefix -> NWConnection -> TLS-PSK encrypt -> TCP segment -> Wi-Fi -> TCP reassemble -> TLS decrypt -> NWConnection receive -> length-prefix parse -> Swift handler(Data)"
            ),
            BridgeDetail(
                id: "flutter",
                name: "Flutter Channel",
                icon: "bird",
                technology: "FlutterEngine + FlutterMethodChannel + AOT Dart isolate",
                processBoundary: "None (in-process)",
                serialization: "StandardMethodCodec (binary)",
                binaryData: "Uint8List (zero-copy)",
                dominantOverhead: "Thread dispatch between platform and Dart UI threads",
                description: "Real FlutterEngine running a headless Dart isolate compiled ahead-of-time. Data passes through Flutter's StandardMethodCodec binary serialization and cross-thread dispatch.",
                dataPath: "Swift -> FlutterStandardTypedData -> channel.invokeMethod() -> StandardMethodCodec encode -> Dart VM thread -> Dart handler -> encode result -> platform callback -> Swift"
            ),
            BridgeDetail(
                id: "reactnative",
                name: "React Native Bridge",
                icon: "atom",
                technology: "RCTBridge + Hermes engine + ObjC RCT_EXPORT_MODULE",
                processBoundary: "None (in-process)",
                serialization: "JSON + MessageQueue batching",
                binaryData: "Base64",
                dominantOverhead: "MessageQueue batch interval (~5ms) + JSON serialization",
                description: "Real RCTBridge running the Hermes JS engine with AOT bytecode. Uses a real ObjC native module that processes every message through the full BatchedBridge pipeline — the same code path used by production React Native apps.",
                dataPath: "Swift -> bridge.enqueueJSCall() -> Hermes JS thread -> BatchedBridge -> NativeModules.BridgeEchoModule.echo() -> ObjC native module -> resolve() -> callback -> Swift"
            ),
            BridgeDetail(
                id: "cordova",
                name: "Cordova JS Bridge",
                icon: "globe",
                technology: "WKWebView + cordova.js + CDVPlugin + CDVPluginResult",
                processBoundary: "Yes (WKWebView — separate process)",
                serialization: "JSON",
                binaryData: "Base64 only",
                dominantOverhead: "WKWebView cross-process IPC + JSON + Base64",
                description: "Real WKWebView running real cordova.js with a real CDVPlugin subclass. Every call crosses the WebKit process boundary twice (App -> WebContent -> App), adding significant latency.",
                dataPath: "Swift -> evaluateJavaScript() -> [WebKit IPC] -> cordova.exec() -> [WebKit IPC] -> WKScriptMessageHandler -> CDVPlugin.echo() -> CDVPluginResult -> evaluateJavaScript(nativeCallback) -> [WebKit IPC] -> Swift"
            ),
            BridgeDetail(
                id: "capacitor",
                name: "Capacitor Bridge",
                icon: "bolt.fill",
                technology: "CAPBridgeViewController + CAPPlugin + WKWebView IPC",
                processBoundary: "Yes (WKWebView — separate process)",
                serialization: "JSON",
                binaryData: "Base64 only",
                dominantOverhead: "WKWebView cross-process IPC + JSON + Base64",
                description: "Real CAPBridgeViewController with Capacitor's native-bridge.js and a real CAPPlugin subclass. Same WKWebView process boundary as Cordova but with Capacitor's cleaner plugin architecture.",
                dataPath: "Swift -> evaluateJavaScript() -> [WebKit IPC] -> Capacitor.Plugins.echo() -> Capacitor.toNative() -> [WebKit IPC] -> CAPPluginCall -> resolve() -> evaluateJavaScript(fromNative) -> [WebKit IPC] -> Swift"
            ),
        ]
    }

    // MARK: - Bridge Status

    private var bridgeStatusSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Runtime Status", systemImage: "checkmark.shield")
                .font(.headline)

            Text(
                "All bridge runtimes are pre-warmed at app launch. Status shows whether the runtime initialized successfully."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            VStack(spacing: 6) {
                ForEach(BridgeRegistry.available, id: \.id) { info in
                    HStack {
                        let bridge = bridges.first { $0.id == info.id }
                        Image(systemName: bridge?.icon ?? "questionmark")
                            .foregroundStyle(Color.bridgeColor(info.id, scheme: colorScheme))
                            .frame(width: 24)
                        Text(info.label)
                            .font(.subheadline)
                        Spacer()
                        BridgeHealthBadge(bridgeID: info.id)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Bridge Row

    private func bridgeRow(_ bridge: BridgeDetail) -> some View {
        let isExpanded = expandedBridge == bridge.id
        let color = Color.bridgeColor(bridge.id, scheme: colorScheme)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    expandedBridge = isExpanded ? nil : bridge.id
                }
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(color.opacity(0.15))
                            .frame(width: 40, height: 40)
                        Image(systemName: bridge.icon)
                            .foregroundStyle(color)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(bridge.name)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(.primary)
                        Text(bridge.technology)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
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
                        Text("Overview")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(Color.adaptive(.blue, scheme: colorScheme))
                        Text(bridge.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Characteristics")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(Color.adaptive(.orange, scheme: colorScheme))
                        detailRow("Process boundary", bridge.processBoundary)
                        detailRow("Serialization", bridge.serialization)
                        detailRow("Binary data", bridge.binaryData)
                        detailRow("Dominant overhead", bridge.dominantOverhead)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Data Path")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(Color.adaptive(.purple, scheme: colorScheme))
                        Text(bridge.dataPath)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.leading, 36)
                .padding(.bottom, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: - How It Works

    private var howItWorksSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("How Bridge Testing Works", systemImage: "gearshape.2")
                .font(.headline)

            step(
                number: 1,
                text: "Each bridge runtime is pre-warmed at app launch so startup time doesn't affect measurements"
            )
            step(
                number: 2,
                text: "When a bridge is selected, every message passes through the real framework runtime before hitting the network"
            )
            step(number: 3, text: "Both sides of the connection use the same bridge — matching how real apps work")
            step(number: 4, text: "The overhead delta vs Native baseline reveals how much latency the framework adds")
            step(
                number: 5,
                text: "Reports include which bridge was used, enabling cross-bridge comparison in analytics"
            )
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func step(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.adaptive(.purple, scheme: colorScheme), in: Circle())
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Overhead Comparison (measured, never estimated)

    /// One device pair's measured bridge results. Only reports for a single
    /// chip pair are compared against each other — mixing hardware would make
    /// the deltas meaningless.
    private struct MeasuredComparison {
        let pairLabel: String
        let rows: [BridgeComparisonRow]
        let nativeBaselineMs: Double?
    }

    /// The device pair with the most bridges actually MEASURED — the only
    /// apples-to-apples comparison the saved reports can support. Returns nil only
    /// when no pair has any measured bridge rows at all.
    ///
    /// The candidate must be chosen AFTER `bridgeComparison` has dropped unmeasured
    /// rows. Ranking raw summaries first meant a pair with many cancelled reports won
    /// the ranking, produced zero rows, and the screen claimed "No bridge measurements
    /// recorded yet" while another pair had perfectly good data.
    private var measuredComparison: MeasuredComparison? {
        let byPair = Dictionary(grouping: store.summaries) { "\($0.localChip)|\($0.remoteChip)" }

        let candidates: [MeasuredComparison] = byPair.values.compactMap { summaries in
            guard let sample = summaries.first else { return nil }
            let rows = store.bridgeComparison(local: sample.localChip, remote: sample.remoteChip)
            guard !rows.isEmpty else { return nil }
            return MeasuredComparison(
                pairLabel: "\(sample.localChip) → \(sample.remoteChip)",
                // bridgeComparison only returns rows with measured latency, so the
                // sort key is always present.
                rows: rows.sorted { ($0.avgLatency ?? 0) < ($1.avgLatency ?? 0) },
                nativeBaselineMs: rows.first { $0.bridge == "native" }?.avgLatency
            )
        }

        // Rank on measured evidence: most bridges compared, then most reports behind
        // those measurements, then a stable label so the screen does not flip between
        // equally-good pairs on redraw.
        return candidates.max { lhs, rhs in
            let lhsKey = (lhs.rows.count, lhs.rows.reduce(0) { $0 + $1.measuredLatencyCount })
            let rhsKey = (rhs.rows.count, rhs.rows.reduce(0) { $0 + $1.measuredLatencyCount })
            if lhsKey != rhsKey {
                return lhsKey < rhsKey
            }
            return lhs.pairLabel > rhs.pairLabel
        }
    }

    private var overheadSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Overhead Comparison", systemImage: "chart.bar")
                .font(.headline)

            if let comparison = measuredComparison {
                measuredOverhead(comparison)
            } else {
                noMeasurementsState
            }

            Text(
                "WKWebView-based bridges (Cordova, Capacitor) cross a process boundary twice per message; in-process bridges (Flutter, React Native) avoid that but still pay for serialization and thread dispatch. The numbers above are whatever this device actually measured — nothing here is estimated."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .italic()
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func measuredOverhead(_ comparison: MeasuredComparison) -> some View {
        let maxLatency = comparison.rows.compactMap(\.avgLatency).max() ?? 0
        return VStack(alignment: .leading, spacing: 10) {
            Text(
                "Average round-trip latency measured on this device for \(comparison.pairLabel), from saved test reports."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            VStack(spacing: 6) {
                ForEach(comparison.rows) { row in
                    overheadRow(row, maxLatency: maxLatency, baseline: comparison.nativeBaselineMs)
                }
            }

            if comparison.nativeBaselineMs == nil {
                Text(
                    "No native run saved for this pair yet, so no baseline delta can be computed — run the suite over the Native transport to get one."
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            if !recordedBridgeCounts.isEmpty {
                Text("Reports on record: \(recordedBridgeCounts)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// "native 4, cordova 2" — measured coverage across all saved reports.
    private var recordedBridgeCounts: String {
        store.availableBridgeTransports()
            .map { "\($0) \(store.summaries(forBridge: $0).count)" }
            .joined(separator: ", ")
    }

    private var noMeasurementsState: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "chart.bar.doc.horizontal")
                    .foregroundStyle(.secondary)
                Text("No bridge measurements recorded yet")
                    .font(.subheadline)
                    .fontWeight(.medium)
            }
            Text(
                "Run a bridge comparison in Conductor mode — or run the test suite once per bridge — and the measured overhead for your own devices will appear here. This app never shows estimated numbers."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    private func overheadRow(_ row: BridgeComparisonRow, maxLatency: Double, baseline: Double?) -> some View {
        let ratio = maxLatency > 0 ? (row.avgLatency ?? 0) / maxLatency : 0
        let color = Color.bridgeColor(row.bridge, scheme: colorScheme)
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(row.bridge)
                    .font(.caption)
                // Count the reports the figure was averaged over, not every report
                // filed under this bridge — they differ when a run measured nothing.
                Text("\(row.measuredLatencyCount) measured")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 90, alignment: .leading)

            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 3)
                    .fill(color.opacity(0.6))
                    .frame(width: max(geo.size.width * ratio, 4))
            }
            .frame(height: 16)

            VStack(alignment: .trailing, spacing: 1) {
                Text(row.avgLatency.map { String(format: "%.2f ms", $0) } ?? "—")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let baseline, baseline > 0, row.bridge != "native" {
                    Text(row.avgLatency.map { String(format: "%+.0f%%", ($0 / baseline - 1) * 100) } ?? "—")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(color)
                } else if row.bridge == "native" {
                    Text("baseline")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 84, alignment: .trailing)
        }
    }
}

// MARK: - Bridge Health Badge

struct BridgeHealthBadge: View {
    let bridgeID: String
    @Environment(\.colorScheme) private var colorScheme
    @State private var healthy: Bool?

    var body: some View {
        Group {
            if bridgeID == "native" {
                badge("Baseline", Color.statusColor(true, scheme: colorScheme))
            } else if let healthy {
                badge(healthy ? "Ready" : "Failed", Color.statusColor(healthy, scheme: colorScheme))
            } else {
                badge("Checking...", Color.adaptive(.gray, scheme: colorScheme))
            }
        }
        .task {
            healthy = await BridgeRegistry.isBridgeHealthy(bridgeID)
        }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2)
            .fontWeight(.medium)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }
}
