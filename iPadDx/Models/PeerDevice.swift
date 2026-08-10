import Foundation
import Network

enum AppMode: String {
    case standalone = "Standalone"
    case conductor = "Conductor"
    case agent = "Agent"
}

enum DeviceRole: String {
    case controller = "Controller"
    case responder = "Responder"
    case none = "Not Assigned"
}

@Observable
class PeerDevice: Identifiable, Hashable {
    static func == (lhs: PeerDevice, rhs: PeerDevice) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    let id: UUID
    var name: String
    /// Refreshed on each browse update: mDNS can hand back a new endpoint for the
    /// same service, and the peer object is reused so its learned identity survives.
    var endpoint: NWEndpoint
    var connectionState: ConnectionState = .discovered
    var metrics: DiagnosticMetrics = .init()
    var role: DeviceRole = .none
    var stableDeviceID: UUID?
    var bonjourName: String? // the actual Bonjour service name (may differ from display name)
    var chipFamily: String?
    var model: String?

    init(id: UUID = UUID(), name: String, endpoint: NWEndpoint) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
    }
}
