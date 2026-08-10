import Network
import XCTest
@testable import iPadDx

final class ConductorServiceTests: XCTestCase {
    // MARK: - Helpers

    @MainActor
    private func makeConnectedDevice(name: String) -> DeviceConnection {
        let endpoint = NWEndpoint.hostPort(host: .name("\(name).local", nil), port: 1234)
        let peer = PeerDevice(name: name, endpoint: endpoint)
        let cm = ConnectionManager(label: "test-\(name)")
        cm.isConnected = true
        return DeviceConnection(peer: peer, connectionManager: cm)
    }

    @MainActor
    private func makeService(deviceNames: [String], bridges: [String] = ["native"]) -> ConductorService {
        let svc = ConductorService()
        svc.includeSelf = false
        svc.selectedBridges = bridges
        svc.fleet = deviceNames.map { makeConnectedDevice(name: $0) }
        return svc
    }

    // MARK: - Pair Count

    @MainActor
    func testTwoDevicesOneBridgeProducesTwoPairs() {
        let svc = makeService(deviceNames: ["A", "B"])
        svc.generateAllPairs()
        // 2 devices → 2×1 = 2 ordered pairs
        XCTAssertEqual(svc.testQueue.count, 2)
    }

    @MainActor
    func testThreeDevicesOneBridgeProducesSixPairs() {
        let svc = makeService(deviceNames: ["A", "B", "C"])
        svc.generateAllPairs()
        // 3 devices → 3×2 = 6 ordered pairs
        XCTAssertEqual(svc.testQueue.count, 6)
    }

    @MainActor
    func testFourDevicesOneBridgeProducesTwelvePairs() {
        let svc = makeService(deviceNames: ["A", "B", "C", "D"])
        svc.generateAllPairs()
        // 4 devices → 4×3 = 12 ordered pairs
        XCTAssertEqual(svc.testQueue.count, 12)
    }

    @MainActor
    func testSingleDeviceProducesEmptyQueue() {
        let svc = makeService(deviceNames: ["A"])
        svc.generateAllPairs()
        XCTAssertTrue(svc.testQueue.isEmpty)
    }

    @MainActor
    func testNoDevicesProducesEmptyQueue() {
        let svc = makeService(deviceNames: [])
        svc.generateAllPairs()
        XCTAssertTrue(svc.testQueue.isEmpty)
    }

    // MARK: - Bridge Multiplication

    @MainActor
    func testTwoDevicesTwoBridgesProducesFourRuns() {
        let svc = makeService(deviceNames: ["A", "B"], bridges: ["native", "cordova"])
        svc.generateAllPairs()
        // 2 pairs × 2 bridges = 4
        XCTAssertEqual(svc.testQueue.count, 4)
    }

    @MainActor
    func testThreeDevicesThreeBridgesProducesEighteenRuns() {
        let svc = makeService(deviceNames: ["A", "B", "C"], bridges: ["native", "cordova", "flutter"])
        svc.generateAllPairs()
        // 6 pairs × 3 bridges = 18
        XCTAssertEqual(svc.testQueue.count, 18)
    }

    // MARK: - Bridge Interleaving

    @MainActor
    func testTwoBridgesInterleavesBridgesAcrossQueue() {
        let svc = makeService(deviceNames: ["A", "B"], bridges: ["native", "cordova"])
        svc.generateAllPairs()
        // Expected interleaved order: pair0/native, pair0/cordova, pair1/native, pair1/cordova
        // Verify no two consecutive entries share the same bridge
        let bridges = svc.testQueue.map(\.bridgeTransport)
        for i in stride(from: 0, to: bridges.count - 1, by: 1) {
            if bridges[i] == bridges[i + 1] {
                XCTFail(
                    "Consecutive runs at indices \(i) and \(i + 1) use the same bridge '\(bridges[i])' — interleaving broken"
                )
            }
        }
    }

    @MainActor
    func testSingleBridgeDoesNotInterleave() {
        let svc = makeService(deviceNames: ["A", "B", "C"], bridges: ["native"])
        svc.generateAllPairs()
        XCTAssertTrue(svc.testQueue.allSatisfy { $0.bridgeTransport == "native" })
    }

    // MARK: - All Directed Pairs Present

    @MainActor
    func testAllDirectedPairsPresent() {
        let svc = makeService(deviceNames: ["A", "B", "C"])
        svc.generateAllPairs()
        let pairs = svc.testQueue.map { ("\($0.deviceA.name)", "\($0.deviceB.name)") }
        let expected: [(String, String)] = [
            ("A", "B"), ("A", "C"),
            ("B", "A"), ("B", "C"),
            ("C", "A"), ("C", "B"),
        ]
        for exp in expected {
            XCTAssertTrue(pairs.contains { $0 == exp }, "Missing pair \(exp.0) → \(exp.1)")
        }
        // No self-pairs
        for run in svc.testQueue {
            XCTAssertNotEqual(run.deviceA.id, run.deviceB.id, "Self-pair found for \(run.deviceA.name)")
        }
    }

    // MARK: - Queue Cleared on Regenerate

    @MainActor
    func testRegeneratingClearsExistingQueue() {
        let svc = makeService(deviceNames: ["A", "B"])
        svc.generateAllPairs()
        let firstCount = svc.testQueue.count

        // Regenerate — should get same count from scratch, not accumulate
        svc.generateAllPairs()
        XCTAssertEqual(svc.testQueue.count, firstCount)
    }

    // MARK: - Disconnected Devices Excluded

    @MainActor
    func testDisconnectedDevicesNotIncluded() {
        let svc = ConductorService()
        svc.includeSelf = false
        svc.selectedBridges = ["native"]

        let endpoint = NWEndpoint.hostPort(host: .name("test.local", nil), port: 1234)
        let connectedPeer = PeerDevice(name: "Connected", endpoint: endpoint)
        let disconnectedPeer = PeerDevice(name: "Disconnected", endpoint: endpoint)

        let connectedCM = ConnectionManager(label: "connected")
        connectedCM.isConnected = true
        let disconnectedCM = ConnectionManager(label: "disconnected")
        // isConnected stays false

        svc.fleet = [
            DeviceConnection(peer: connectedPeer, connectionManager: connectedCM),
            DeviceConnection(peer: disconnectedPeer, connectionManager: disconnectedCM),
        ]

        svc.generateAllPairs()
        // Only 1 connected device — no valid pairs
        XCTAssertTrue(svc.testQueue.isEmpty)
    }
}
