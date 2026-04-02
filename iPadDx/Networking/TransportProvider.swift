import Foundation
import Network

/// Connection transport state.
enum TransportState {
    case preparing
    case ready
    case failed(Error)
    case disconnected
}

/// Abstraction over the raw network transport layer.
///
/// `ConnectionManager` delegates actual data movement to a `TransportProvider`.
/// The native transport talks directly to `NWConnection`; bridge transports
/// (Cordova, React Native, …) route data through their respective runtimes
/// before hitting the network, measuring the real overhead that end-users experience.
protocol TransportProvider: AnyObject {
    /// Short identifier: "native", "cordova", "reactnative", "flutter", "capacitor".
    var bridgeID: String { get }

    /// Human-readable label shown in UI: "Native (baseline)", "Cordova JS Bridge", etc.
    var bridgeLabel: String { get }

    /// Initiate an outbound connection to `endpoint`.
    func connect(to endpoint: NWEndpoint, queue: DispatchQueue)

    /// Accept an already-established inbound connection.
    func accept(_ connection: NWConnection, queue: DispatchQueue)

    /// Send raw framed data. Callers are responsible for length-prefix framing.
    func send(_ data: Data, completion: @escaping (NWError?) -> Void)

    /// Begin the receive loop. `handler` is called once per complete frame.
    func startReceiving(
        handler: @escaping (Data) -> Void,
        onEOF: @escaping () -> Void,
        onError: @escaping (NWError) -> Void
    )

    /// Tear down the connection.
    func disconnect()

    /// Current NWPath for the underlying connection (if applicable).
    var currentPath: NWPath? { get }

    /// Called when the transport's connection state changes.
    var onStateChange: ((TransportState) -> Void)? { get set }
}

/// A registered bridge transport.
struct BridgeInfo: Identifiable {
    let id: String
    let label: String
    let enabled: Bool
}

/// Registry of available bridge transports.
enum BridgeRegistry {
    /// All bridge transports supported by this build.
    /// The first entry is always `native` (baseline).
    static let available: [BridgeInfo] = [
        BridgeInfo(id: "native", label: "Native (baseline)", enabled: true),
        BridgeInfo(id: "cordova", label: "Cordova JS Bridge", enabled: true),
        BridgeInfo(id: "reactnative", label: "React Native Bridge", enabled: true),
        BridgeInfo(id: "flutter", label: "Flutter Channel", enabled: true),
        BridgeInfo(id: "capacitor", label: "Capacitor Bridge", enabled: true),
    ]

    /// Create a transport provider for the given bridge ID.
    /// Returns nil if the bridge is not available in this build.
    static func transport(for bridgeID: String) -> TransportProvider? {
        switch bridgeID {
        case "native": NativeTransport()
        case "cordova": CordovaTransport()
        case "reactnative": ReactNativeTransport()
        case "flutter": FlutterTransport()
        case "capacitor": CapacitorTransport()
        default: nil
        }
    }

    /// Bridge IDs that are actually usable (compiled into this build).
    static var enabledBridgeIDs: [String] {
        available.filter(\.enabled).map(\.id)
    }
}
