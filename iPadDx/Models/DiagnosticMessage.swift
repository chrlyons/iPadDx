import Foundation

enum DiagnosticMessage: Codable {
    case ping(id: UUID, timestamp: TimeInterval)
    case pong(id: UUID, originalTimestamp: TimeInterval)
    case throughputStart(testID: UUID, byteCount: Int)
    case throughputData(testID: UUID)
    case throughputAck(testID: UUID, bytesReceived: Int, duration: TimeInterval)
    case peerInfo(deviceName: String, osVersion: String, model: String)
    case testPing(id: UUID, sequence: Int, timestamp: TimeInterval)
    case testPong(id: UUID, sequence: Int, originalTimestamp: TimeInterval)
    case testSuiteStatus(running: Bool, phase: String)

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
