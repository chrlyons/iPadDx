import SwiftUI

struct FleetDeviceCard: View {
    let connection: DeviceConnection
    let onDisconnect: () -> Void

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
                        .background(.blue.opacity(0.1), in: Capsule())
                }
                if let model = connection.peer.model {
                    Text(model)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
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
                    .foregroundStyle(connection.agentStatus == .failed ? .red : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Progress bar during testing
            if connection.agentStatus == .testing, connection.testProgress > 0 {
                ProgressView(value: connection.testProgress)
                    .tint(.blue)
            }
        }
        .padding()
        .background(statusBackground, in: RoundedRectangle(cornerRadius: 12))
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var statusColor: Color {
        switch connection.agentStatus {
        case .connected, .idle: .green
        case .connecting: .yellow
        case .testing: .blue
        case .completed: .green
        case .failed: .red
        }
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
        case .testing: .blue.opacity(0.05)
        case .failed: .red.opacity(0.05)
        case .completed: .green.opacity(0.05)
        default: .clear
        }
    }
}

/// Card for the conductor's own device in the fleet grid
struct SelfDeviceCard: View {
    let info: DeviceInfo
    let isTesting: Bool

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Circle()
                    .fill(isTesting ? .blue : .green)
                    .frame(width: 10, height: 10)
                Text(info.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                Image(systemName: "star.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Text(info.chipFamily)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.orange.opacity(0.1), in: Capsule())
                Text(info.displayModel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            HStack {
                Image(systemName: isTesting ? "bolt.fill" : "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(isTesting ? .blue : .green)
                Text(isTesting ? "Testing" : "Conductor")
                    .font(.caption)
                    .foregroundStyle(isTesting ? .blue : .green)
                Spacer()
            }
        }
        .padding()
        .background(isTesting ? .blue.opacity(0.05) : .orange.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
