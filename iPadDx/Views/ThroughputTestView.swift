import SwiftUI

struct ThroughputTestView: View {
    let metrics: DiagnosticMetrics
    let onRunTest: () -> Void
    @State private var showTooltip = false

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "arrow.up.arrow.down.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.purple)
                Text("Throughput")
                    .font(.headline)
                Spacer()
                Button {
                    showTooltip = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if metrics.throughputTestInProgress {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Running throughput test...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            } else {
                Text(metrics.formattedThroughput)
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .foregroundStyle(.purple)

                Button {
                    onRunTest()
                } label: {
                    Label("Run Test", systemImage: "play.fill")
                        .font(.subheadline)
                        .fontWeight(.medium)
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .alert("Throughput", isPresented: $showTooltip) {
            Button("OK") {}
        } message: {
            Text(
                "Measures data transfer speed by sending 1 MB of data to the other device. The result shows how many megabytes per second can be transferred. Higher is better. Each device measures independently, so results may differ between sender and receiver."
            )
        }
    }
}
