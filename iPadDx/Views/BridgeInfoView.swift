import SwiftUI

struct BridgeInfoView: View {
    @State private var expandedBridge: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Header
                VStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 50))
                        .foregroundStyle(.purple)
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
        let color: Color
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
                color: .green,
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
                color: .blue,
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
                color: .purple,
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
                color: .orange,
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
                color: .teal,
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
                            .foregroundStyle(bridge?.color ?? .gray)
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
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    expandedBridge = isExpanded ? nil : bridge.id
                }
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(bridge.color.opacity(0.15))
                            .frame(width: 40, height: 40)
                        Image(systemName: bridge.icon)
                            .foregroundStyle(bridge.color)
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
                            .foregroundStyle(.blue)
                        Text(bridge.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Characteristics")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.orange)
                        detailRow("Process boundary", bridge.processBoundary)
                        detailRow("Serialization", bridge.serialization)
                        detailRow("Binary data", bridge.binaryData)
                        detailRow("Dominant overhead", bridge.dominantOverhead)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Data Path")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.purple)
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
                .background(.purple, in: Circle())
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Overhead Comparison

    private var overheadSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Overhead Comparison", systemImage: "chart.bar")
                .font(.headline)

            Text(
                "Typical overhead added by each bridge on top of the native baseline. Actual values depend on device, payload size, and network conditions."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            VStack(spacing: 6) {
                overheadRow("Native", "+0%", .green, 0)
                overheadRow("Flutter", "+70-80%", .blue, 0.75)
                overheadRow("React Native", "+75-85%", .purple, 0.80)
                overheadRow("Capacitor", "+95-105%", .teal, 1.0)
                overheadRow("Cordova", "+100-110%", .orange, 1.05)
            }

            Text(
                "WKWebView-based bridges (Cordova, Capacitor) have the highest overhead due to cross-process IPC. In-process bridges (Flutter, React Native) are faster but still add serialization and thread dispatch costs."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .italic()
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func overheadRow(_ name: String, _ label: String, _ color: Color, _ ratio: Double) -> some View {
        HStack(spacing: 8) {
            Text(name)
                .font(.caption)
                .frame(width: 90, alignment: .leading)
            GeometryReader { geo in
                let width = max(geo.size.width * min(ratio / 1.2, 1.0), ratio == 0 ? 4 : 20)
                RoundedRectangle(cornerRadius: 3)
                    .fill(color.opacity(0.6))
                    .frame(width: width)
            }
            .frame(height: 16)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
        }
    }
}

// MARK: - Bridge Health Badge

struct BridgeHealthBadge: View {
    let bridgeID: String
    @State private var healthy: Bool?

    var body: some View {
        Group {
            if bridgeID == "native" {
                badge("Baseline", .green)
            } else if let healthy {
                badge(healthy ? "Ready" : "Failed", healthy ? .green : .red)
            } else {
                badge("Checking...", .gray)
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
