import XCTest
@testable import iPadDx

final class DiagnosticMessageTests: XCTestCase {
    // MARK: - Round-trip encoding/decoding

    func testPingRoundTrip() throws {
        let id = UUID()
        let ts: TimeInterval = 123_456.789
        let msg = DiagnosticMessage.ping(id: id, timestamp: ts)
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(DiagnosticMessage.self, from: data)
        if case let .ping(decodedID, decodedTS) = decoded {
            XCTAssertEqual(decodedID, id)
            XCTAssertEqual(decodedTS, ts)
        } else {
            XCTFail("Expected .ping, got \(decoded)")
        }
    }

    func testPongRoundTrip() throws {
        let id = UUID()
        let ts: TimeInterval = 99.99
        let msg = DiagnosticMessage.pong(id: id, originalTimestamp: ts)
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(DiagnosticMessage.self, from: data)
        if case let .pong(decodedID, decodedTS) = decoded {
            XCTAssertEqual(decodedID, id)
            XCTAssertEqual(decodedTS, ts)
        } else {
            XCTFail("Expected .pong, got \(decoded)")
        }
    }

    func testThroughputStartRoundTrip() throws {
        let id = UUID()
        let msg = DiagnosticMessage.throughputStart(testID: id, byteCount: 1_000_000)
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(DiagnosticMessage.self, from: data)
        if case let .throughputStart(decodedID, byteCount) = decoded {
            XCTAssertEqual(decodedID, id)
            XCTAssertEqual(byteCount, 1_000_000)
        } else {
            XCTFail("Expected .throughputStart, got \(decoded)")
        }
    }

    func testThroughputAckRoundTrip() throws {
        let id = UUID()
        let msg = DiagnosticMessage.throughputAck(testID: id, bytesReceived: 500_000, duration: 1.5)
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(DiagnosticMessage.self, from: data)
        if case let .throughputAck(decodedID, bytes, duration) = decoded {
            XCTAssertEqual(decodedID, id)
            XCTAssertEqual(bytes, 500_000)
            XCTAssertEqual(duration, 1.5)
        } else {
            XCTFail("Expected .throughputAck, got \(decoded)")
        }
    }

    func testPeerInfoRoundTrip() throws {
        let stableID = UUID()
        let msg = DiagnosticMessage.peerInfo(
            deviceName: "iPad Pro",
            osVersion: "18.4",
            model: "iPad Pro 13-inch (M4)",
            modelNumber: "iPad16,5",
            stableID: stableID,
            ssid: "TestNetwork",
            bssid: "AA:BB:CC:DD:EE:FF"
        )
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(DiagnosticMessage.self, from: data)
        if case let .peerInfo(name, os, model, modelNum, sid, ssid, bssid) = decoded {
            XCTAssertEqual(name, "iPad Pro")
            XCTAssertEqual(os, "18.4")
            XCTAssertEqual(model, "iPad Pro 13-inch (M4)")
            XCTAssertEqual(modelNum, "iPad16,5")
            XCTAssertEqual(sid, stableID)
            XCTAssertEqual(ssid, "TestNetwork")
            XCTAssertEqual(bssid, "AA:BB:CC:DD:EE:FF")
        } else {
            XCTFail("Expected .peerInfo, got \(decoded)")
        }
    }

    func testPeerInfoNilWiFiRoundTrip() throws {
        let stableID = UUID()
        let msg = DiagnosticMessage.peerInfo(
            deviceName: "iPad",
            osVersion: "17.0",
            model: "iPad",
            modelNumber: "iPad14,1",
            stableID: stableID,
            ssid: nil,
            bssid: nil
        )
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(DiagnosticMessage.self, from: data)
        if case let .peerInfo(_, _, _, _, _, ssid, bssid) = decoded {
            XCTAssertNil(ssid)
            XCTAssertNil(bssid)
        } else {
            XCTFail("Expected .peerInfo, got \(decoded)")
        }
    }

    func testTestPingRoundTrip() throws {
        let id = UUID()
        let msg = DiagnosticMessage.testPing(id: id, sequence: 42, timestamp: 100.0)
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(DiagnosticMessage.self, from: data)
        if case let .testPing(decodedID, seq, ts) = decoded {
            XCTAssertEqual(decodedID, id)
            XCTAssertEqual(seq, 42)
            XCTAssertEqual(ts, 100.0)
        } else {
            XCTFail("Expected .testPing, got \(decoded)")
        }
    }

    func testOrchestrationMessages() throws {
        let messages: [DiagnosticMessage] = [
            .roleAssignment(role: "controller"),
            .orchestrationStatus(phase: "latency", detail: "50%"),
            .orchestrationCancel,
            .agentCapabilities(supportedBridges: ["native", "cordova", "flutter"]),
        ]
        for msg in messages {
            let data = try JSONEncoder().encode(msg)
            let decoded = try JSONDecoder().decode(DiagnosticMessage.self, from: data)
            // Verify round-trip doesn't throw
            let reEncoded = try JSONEncoder().encode(decoded)
            XCTAssertFalse(reEncoded.isEmpty)
        }
    }

    func testResponderMetricsRoundTrip() throws {
        let msg = DiagnosticMessage.responderMetrics(
            peakCpu: 85.5,
            avgCpu: 42.3,
            peakMemoryMB: 256.0,
            thermalState: "Fair",
            batteryDrain: 2.5
        )
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(DiagnosticMessage.self, from: data)
        if case let .responderMetrics(peak, avg, mem, thermal, drain) = decoded {
            XCTAssertEqual(peak, 85.5)
            XCTAssertEqual(avg, 42.3)
            XCTAssertEqual(mem, 256.0)
            XCTAssertEqual(thermal, "Fair")
            XCTAssertEqual(drain, 2.5)
        } else {
            XCTFail("Expected .responderMetrics, got \(decoded)")
        }
    }

    func testDisconnectRoundTrip() throws {
        let msg = DiagnosticMessage.disconnect
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(DiagnosticMessage.self, from: data)
        if case .disconnect = decoded {
            // pass
        } else {
            XCTFail("Expected .disconnect, got \(decoded)")
        }
    }

    // MARK: - Framed encoding

    func testEncodeProducesLengthPrefixedFrame() throws {
        let msg = DiagnosticMessage.ping(id: UUID(), timestamp: 0)
        let frame = try msg.encode()

        // First 4 bytes are big-endian UInt32 length
        let length = frame.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
        XCTAssertEqual(Int(length), frame.count - 4, "Length prefix should equal payload size")

        // Payload should be valid JSON
        let payload = frame.dropFirst(4)
        let decoded = try DiagnosticMessage.decode(from: Data(payload))
        if case .ping = decoded {
            // pass
        } else {
            XCTFail("Decoded frame payload should be .ping")
        }
    }

    func testDecodeFromPayloadOnly() throws {
        let msg = DiagnosticMessage.testSuiteStatus(running: true, phase: "latencyBurst")
        let jsonData = try JSONEncoder().encode(msg)
        let decoded = try DiagnosticMessage.decode(from: jsonData)
        if case let .testSuiteStatus(running, phase) = decoded {
            XCTAssertTrue(running)
            XCTAssertEqual(phase, "latencyBurst")
        } else {
            XCTFail("Expected .testSuiteStatus")
        }
    }

    // MARK: - Invalid data

    func testDecodeInvalidDataThrows() {
        let garbage = Data([0x00, 0xFF, 0xAB])
        XCTAssertThrowsError(try DiagnosticMessage.decode(from: garbage))
    }

    func testDecodeEmptyDataThrows() {
        XCTAssertThrowsError(try DiagnosticMessage.decode(from: Data()))
    }

    // MARK: - orchestrateTest with bridge transport

    func testOrchestrateTestDefaultBridge() throws {
        let configData = try JSONEncoder().encode(TestSuiteConfig.default)
        let msg = DiagnosticMessage.orchestrateTest(
            targetDeviceName: "iPad A",
            configJSON: configData,
            role: "controller"
        )
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(DiagnosticMessage.self, from: data)
        if case let .orchestrateTest(_, _, _, bridge) = decoded {
            XCTAssertEqual(bridge, "native")
        } else {
            XCTFail("Expected .orchestrateTest")
        }
    }

    func testOrchestrateTestCustomBridge() throws {
        let configData = try JSONEncoder().encode(TestSuiteConfig.default)
        let msg = DiagnosticMessage.orchestrateTest(
            targetDeviceName: "iPad B",
            configJSON: configData,
            role: "responder",
            bridgeTransport: "cordova"
        )
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(DiagnosticMessage.self, from: data)
        if case let .orchestrateTest(name, _, role, bridge) = decoded {
            XCTAssertEqual(name, "iPad B")
            XCTAssertEqual(role, "responder")
            XCTAssertEqual(bridge, "cordova")
        } else {
            XCTFail("Expected .orchestrateTest")
        }
    }
}
