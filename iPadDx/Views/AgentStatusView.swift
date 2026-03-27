import SwiftUI

struct AgentStatusView: View {
    @Environment(BonjourService.self) private var service

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Header
                VStack(spacing: 12) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 50))
                        .foregroundStyle(.orange)
                        .symbolEffect(.pulse, isActive: service.agentService?.status == .testing)

                    Text("Agent Mode")
                        .font(.title2)
                        .fontWeight(.bold)

                    if !conductorName.isEmpty {
                        Text("Connected to conductor: \(conductorName)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))

                // Status
                statusCard

                // Actions
                Button {
                    service.leaveAgentMode()
                } label: {
                    Label("Leave Agent Mode", systemImage: "escape")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding()
        }
        .navigationTitle("Agent")
    }

    private var conductorName: String {
        service.agentService?.conductorName ?? ""
    }

    private var statusCard: some View {
        VStack(spacing: 12) {
            if let agent = service.agentService {
                switch agent.status {
                case .idle, .connected:
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.green)
                        VStack(alignment: .leading) {
                            Text("Ready")
                                .font(.headline)
                            Text("Waiting for test instructions from conductor")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }

                case .connecting:
                    HStack(spacing: 12) {
                        ProgressView()
                        VStack(alignment: .leading) {
                            Text("Connecting to test partner")
                                .font(.headline)
                            Text(agent.testPartnerName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }

                case .testing:
                    VStack(spacing: 12) {
                        HStack(spacing: 12) {
                            Image(systemName: "testtube.2")
                                .font(.title2)
                                .foregroundStyle(.blue)
                            VStack(alignment: .leading) {
                                Text("Testing with \(agent.testPartnerName)")
                                    .font(.headline)
                                Text(agent.testPhase)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        ProgressView(value: agent.testProgress)
                            .tint(.blue)
                        if agent.liveLatency > 0 {
                            Text(String(format: "Live: %.1fms", agent.liveLatency))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                case .completed:
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.title2)
                            .foregroundStyle(.green)
                        Text("Test completed — report sent to conductor")
                            .font(.subheadline)
                        Spacer()
                    }

                case .failed:
                    HStack(spacing: 12) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.red)
                        Text("Test failed")
                            .font(.subheadline)
                        Spacer()
                    }
                }
            } else {
                Text("Agent service not active")
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
