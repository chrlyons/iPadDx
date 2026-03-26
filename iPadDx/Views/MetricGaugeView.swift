import SwiftUI

struct MetricGaugeView: View {
    let title: String
    let value: String
    let subtitle: String
    let icon: String
    var color: Color = .blue
    var tooltip: String?

    @State private var showTooltip = false

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Spacer()
                if tooltip != nil {
                    Button {
                        showTooltip = true
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(height: 12)

            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)

            Text(value)
                .font(.system(.title, design: .rounded, weight: .bold))
                .foregroundStyle(color)

            Text(title)
                .font(.caption)
                .fontWeight(.medium)

            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .alert(title, isPresented: $showTooltip) {
            Button("OK") {}
        } message: {
            Text(tooltip ?? "")
        }
    }
}
