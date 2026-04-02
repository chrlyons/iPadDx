import Foundation

enum AgentStatus: String {
    case connected = "Connected"
    case idle = "Idle"
    case connecting = "Connecting to Partner"
    case testing = "Testing"
    case completed = "Test Completed"
    case failed = "Failed"
}

@Observable
class DeviceConnection: Identifiable {
    let id: UUID
    let peer: PeerDevice
    let connectionManager: ConnectionManager
    var diagnosticEngine: DiagnosticEngine?
    var agentStatus: AgentStatus = .connected
    var currentTestPartner: String?
    var testProgress: Double = 0
    var testPhase: String = ""
    /// Bridges this agent supports. Populated from agentCapabilities message.
    var supportedBridges: [String] = ["native"]

    init(peer: PeerDevice, connectionManager: ConnectionManager) {
        id = peer.id
        self.peer = peer
        self.connectionManager = connectionManager
    }
}
