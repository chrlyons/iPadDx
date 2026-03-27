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

            HStack {
                Text(connection.agentStatus.rawValue)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                if let partner = connection.currentTestPartner {
                    Text("with \(partner)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    onDisconnect()
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if connection.agentStatus == .testing {
                ProgressView(value: connection.testProgress)
                    .tint(.blue)
                Text(connection.testPhase)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
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
}
