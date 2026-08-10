import Foundation

/// Polls `isReady` at `intervalNs` intervals until it returns true or `maxAttempts` is exhausted.
/// Returns the 0-based attempt index on success, or nil on timeout.
@MainActor
func waitForBridgeReady(
    isReady: () -> Bool,
    maxAttempts: Int = 50,
    intervalNs: UInt64 = 100_000_000
) async -> Int? {
    for attempt in 0 ..< maxAttempts {
        if isReady() {
            return attempt
        }
        try? await Task.sleep(nanoseconds: intervalNs)
    }
    return nil
}

/// Call-id-based request/response registry for bridge transports that use a round-trip
/// echo pattern (Capacitor, Cordova, React Native).
struct BridgeCallbackRegistry {
    private var callbacks: [String: (String) -> Void] = [:]
    private var counter = 0
    private let prefix: String

    init(prefix: String) {
        self.prefix = prefix
    }

    mutating func nextCallId() -> String {
        counter += 1
        return "\(prefix)_\(counter)"
    }

    mutating func register(callId: String, callback: @escaping (String) -> Void) {
        callbacks[callId] = callback
    }

    mutating func cancel(callId: String) {
        callbacks.removeValue(forKey: callId)
    }

    mutating func handle(callId: String, payload: String) {
        callbacks.removeValue(forKey: callId)?(payload)
    }
}
