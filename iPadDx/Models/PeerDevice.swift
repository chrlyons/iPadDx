import Foundation
import Network

enum DeviceRole: String {
    case controller = "Controller"
    case responder = "Responder"
    case none = "Not Assigned"
}

@Observable
class PeerDevice: Identifiable {
    let id: UUID
    var name: String
    let endpoint: NWEndpoint
    var connectionState: ConnectionState = .discovered
    var metrics: DiagnosticMetrics = .init()
    var role: DeviceRole = .none

    init(id: UUID = UUID(), name: String, endpoint: NWEndpoint) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
    }
}
