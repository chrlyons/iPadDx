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
    /// Display name of the current test partner, for the UI only.
    var currentTestPartner: String?
    /// Stable id of the current test partner.
    ///
    /// Report patching must resolve the partner by this, not by display name:
    /// `peer.name` is rewritten whenever a peerInfo message arrives, so a rename or
    /// a timing mismatch would leave the responder unresolved and the report's
    /// "Unknown" device fields unpatched.
    var currentTestPartnerID: UUID?
    var testProgress: Double = 0
    var testPhase: String = ""
    /// Timestamp of last orchestration status update from the agent.
    var lastStatusUpdate: Date = .distantPast
    /// Bridges this agent supports. Populated from agentCapabilities message.
    var supportedBridges: [String] = ["native"]

    init(peer: PeerDevice, connectionManager: ConnectionManager) {
        id = peer.id
        self.peer = peer
        self.connectionManager = connectionManager
    }
}
