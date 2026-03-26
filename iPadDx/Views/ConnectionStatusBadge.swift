import SwiftUI

struct ConnectionStatusBadge: View {
    let state: ConnectionState

    var color: Color {
        switch state {
        case .discovered: .gray
        case .connecting: .yellow
        case .connected: .green
        case .failed: .red
        case .disconnected: .gray
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
            Text(state.rawValue)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
