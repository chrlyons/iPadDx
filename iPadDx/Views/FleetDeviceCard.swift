import SwiftUI

struct FleetDeviceCard: View {
    let connection: DeviceConnection
    let onDisconnect: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                Text(connection.peer.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                Button {
                    onDisconnect()
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                if let chip = connection.peer.chipFamily {
                    Text(chip)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(accent.opacity(0.1), in: Capsule())
                }
                if let model = connection.peer.model {
                    Text(model)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            // Capability badges
            if connection.supportedBridges.count > 1 || connection.supportedBridges.first != "native" {
                HStack(spacing: 4) {
                    ForEach(connection.supportedBridges, id: \.self) { bridge in
                        let color = Color.bridgeColor(bridge, scheme: colorScheme)
                        Text(bridge)
                            .font(.system(size: 9))
                            .fontWeight(.medium)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(color.opacity(0.12), in: Capsule())
                            .foregroundStyle(color)
                    }
                    Spacer()
                }
            }

            // Status line
            HStack {
                Image(systemName: statusIcon)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                Text(connection.agentStatus.rawValue)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                if let partner = connection.currentTestPartner {
                    Text("— \(partner)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            // Detail line (phase info from orchestration status)
            if !connection.testPhase.isEmpty {
                Text(connection.testPhase)
                    .font(.caption2)
                    .foregroundStyle(
                        connection.agentStatus == .failed
                            ? Color.adaptive(.red, scheme: colorScheme)
                            : Color.secondary
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Progress bar during testing
            if connection.agentStatus == .testing, connection.testProgress > 0 {
                ProgressView(value: connection.testProgress)
                    .tint(accent)
            }
        }
        .padding()
        .background(statusBackground, in: RoundedRectangle(cornerRadius: 12))
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    /// Neutral accent used for chip badges and progress.
    private var accent: Color {
        Color.adaptive(.blue, scheme: colorScheme)
    }

    private var statusColor: Color {
        let base: Color = switch connection.agentStatus {
        case .connected, .idle: .green
        case .connecting: .yellow
        case .testing: .blue
        case .completed: .green
        case .failed: .red
        }
        return Color.adaptive(base, scheme: colorScheme)
    }

    private var statusIcon: String {
        switch connection.agentStatus {
        case .connected, .idle: "checkmark.circle.fill"
        case .connecting: "arrow.triangle.2.circlepath"
        case .testing: "bolt.fill"
        case .completed: "checkmark.seal.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var statusBackground: Color {
        switch connection.agentStatus {
        case .testing, .failed, .completed: statusColor.opacity(0.05)
        default: .clear
        }
    }
}

/// Card for the conductor's own device in the fleet grid
struct SelfDeviceCard: View {
    let info: DeviceInfo
    let isTesting: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                Text(info.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                Image(systemName: "star.fill")
                    .font(.caption)
                    .foregroundStyle(conductorAccent)
            }

            HStack {
                Text(info.chipFamily)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(conductorAccent.opacity(0.1), in: Capsule())
                Text(info.displayModel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            HStack {
                Image(systemName: isTesting ? "bolt.fill" : "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(statusColor)
                Text(isTesting ? "Testing" : "Conductor")
                    .font(.caption)
                    .foregroundStyle(statusColor)
                Spacer()
            }
        }
        .padding()
        .background(
            (isTesting ? statusColor : conductorAccent).opacity(0.05),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var statusColor: Color {
        Color.adaptive(isTesting ? .blue : .green, scheme: colorScheme)
    }

    private var conductorAccent: Color {
        Color.adaptive(.orange, scheme: colorScheme)
    }
}
