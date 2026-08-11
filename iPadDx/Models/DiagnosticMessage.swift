import Foundation

/// Real payload bytes used by the throughput phases.
///
/// The throughput measurement is only meaningful if actual bytes cross the wire,
/// so every `throughputData` message carries a chunk from here. The buffer is
/// pseudo-random rather than zero-filled so that no layer can compress it away,
/// and it is generated once and reused to keep the sender's cost negligible.
enum ThroughputPayload {
    /// Documented chunk size: 32 KB of payload per message.
    static let chunkSize = 32768

    /// Reusable full-size chunk.
    static let sharedChunk: Data = make(chunkSize)

    static func make(_ size: Int) -> Data {
        guard size > 0 else { return Data() }
        var bytes = [UInt8](repeating: 0, count: size)
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        for i in 0 ..< size {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            bytes[i] = UInt8(truncatingIfNeeded: seed >> 33)
        }
        return Data(bytes)
    }

    /// A chunk of exactly `size` bytes, reusing the shared buffer where possible.
    static func chunk(ofSize size: Int) -> Data {
        if size == chunkSize {
            return sharedChunk
        }
        if size < chunkSize {
            return Data(sharedChunk.prefix(size))
        }
        return make(size)
    }
}

enum DiagnosticMessage: Codable {
    case ping(id: UUID, timestamp: TimeInterval)
    case pong(id: UUID, originalTimestamp: TimeInterval)
    case throughputStart(testID: UUID, byteCount: Int)
    /// Carries a real chunk of payload bytes. The receiver counts `payload.count`
    /// and acks with the measured total once `throughputStart.byteCount` has arrived.
    case throughputData(testID: UUID, payload: Data)
    /// Sent by the *receiver* back to the sender: how many payload bytes actually
    /// arrived and how long they took. This is the authoritative throughput measurement.
    case throughputAck(testID: UUID, bytesReceived: Int, duration: TimeInterval)
    case peerInfo(
        deviceName: String,
        osVersion: String,
        model: String,
        modelNumber: String,
        stableID: UUID,
        ssid: String? = nil,
        bssid: String? = nil
    )
    case testPing(id: UUID, sequence: Int, timestamp: TimeInterval)
    case testPong(id: UUID, sequence: Int, originalTimestamp: TimeInterval)
    case testSuiteStatus(running: Bool, phase: String)
    case reportSync(reportJSON: Data)
    case disconnect
    // Orchestration
    case roleAssignment(role: String)
    case orchestrateTest(targetDeviceName: String, configJSON: Data, role: String, bridgeTransport: String = "native")
    case orchestrationStatus(phase: String, detail: String)
    case orchestrationReport(reportJSON: Data)
    case orchestrationCancel
    /// Agent advertises which bridge transports it supports.
    case agentCapabilities(supportedBridges: [String], appVersion: String = "", iosVersion: String = "")
    /// Live system metrics broadcast by responder during test (every 2s).
    case liveMetrics(cpu: Double, memoryMB: Double, thermalState: String, timestamp: TimeInterval)
    /// Responder-side system metrics sent back to controller after test
    case responderMetrics(
        peakCpu: Double,
        avgCpu: Double,
        peakMemoryMB: Double,
        thermalState: String,
        batteryDrain: Double
    )

    // MARK: - Serialization

    func encode() throws -> Data {
        let payload = try JSONEncoder().encode(self)
        var length = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(payload)
        return frame
    }

    static func decode(from data: Data) throws -> DiagnosticMessage {
        try JSONDecoder().decode(DiagnosticMessage.self, from: data)
    }
}
