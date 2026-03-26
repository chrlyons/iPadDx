import Foundation
import Network
import UIKit

@MainActor
@Observable
class DiagnosticEngine {
    var metrics: DiagnosticMetrics
    weak var peer: PeerDevice?
    var onPeerNameUpdated: ((String) -> Void)?
    var onTestSuiteStatus: ((DiagnosticMessage) -> Void)?
    var testSuiteRunner: TestSuiteRunner?

    private var connectionManager: ConnectionManager
    private var pingTimer: Timer?
    private var pendingPings: [UUID: TimeInterval] = [:]
    private var throughputTestStart: Date?
    private var throughputTestID: UUID?
    private var throughputBytesSent: Int = 0
    private var incomingThroughputStartTime: Date?
    private var incomingThroughputTestID: UUID?
    private var incomingThroughputExpectedBytes: Int = 0
    private let maxLatencyHistory = 120
    private var lastPathUpdate: TimeInterval = 0
    private var systemTimer: Timer?

    init(connectionManager: ConnectionManager, metrics: DiagnosticMetrics) {
        self.connectionManager = connectionManager
        self.metrics = metrics
    }

    func start() {
        SystemMonitor.enableBatteryMonitoring()
        metrics.connectionStartTime = Date()
        metrics.batteryAtConnectionStart = SystemMonitor.batteryLevel()
        metrics.logEvent("Connected")
        sendPeerInfo()
        startPingLoop()
        startSystemMonitor()
        updatePathInfo()
        updateSystemMetrics()
    }

    func stop() {
        pingTimer?.invalidate()
        pingTimer = nil
        systemTimer?.invalidate()
        systemTimer = nil
        pendingPings.removeAll()
        metrics.logEvent("Disconnected")
        metrics.disconnectionCount += 1
    }

    func handleMessage(_ data: Data) {
        guard let message = try? DiagnosticMessage.decode(from: data) else { return }

        switch message {
        case let .ping(id, timestamp):
            connectionManager.send(.pong(id: id, originalTimestamp: timestamp))

        case let .pong(id, originalTimestamp):
            let rtt = (ProcessInfo.processInfo.systemUptime - originalTimestamp) * 1000
            pendingPings.removeValue(forKey: id)
            metrics.latencyMs = rtt
            metrics.pongsReceived += 1
            metrics.appendLatency(rtt, maxHistory: maxLatencyHistory)

        case let .peerInfo(deviceName, osVersion, model):
            metrics.peerDeviceName = deviceName
            metrics.peerOSVersion = osVersion
            metrics.peerModel = model
            // Update the peer's display name with the real device name
            peer?.name = deviceName
            onPeerNameUpdated?(deviceName)

        case let .throughputStart(testID, byteCount):
            // Remote is starting a throughput test — record the start time
            incomingThroughputStartTime = Date()
            incomingThroughputTestID = testID
            incomingThroughputExpectedBytes = byteCount

        case let .throughputAck(testID, _, duration):
            if testID == incomingThroughputTestID, let startTime = incomingThroughputStartTime {
                // Remote finished sending — measure how long it took to receive
                let elapsed = Date().timeIntervalSince(startTime)
                let bytesPerSec = Double(incomingThroughputExpectedBytes) / elapsed
                metrics.throughputBytesPerSec = bytesPerSec
                incomingThroughputTestID = nil
                incomingThroughputStartTime = nil
            } else if testID == throughputTestID, duration > 0 {
                // This is an ack for a test we initiated (shouldn't happen in new flow)
                let bytesPerSec = Double(throughputBytesSent) / duration
                metrics.throughputBytesPerSec = bytesPerSec
                metrics.throughputTestInProgress = false
                throughputTestID = nil
            }

        case .throughputData:
            break

        case let .testPing(id, sequence, timestamp):
            connectionManager.send(.testPong(id: id, sequence: sequence, originalTimestamp: timestamp))

        case .testPong:
            testSuiteRunner?.handleTestMessage(message)

        case .testSuiteStatus:
            // Forwarded to BonjourService via callback
            onTestSuiteStatus?(message)
        }

        // Only update path/bytes periodically to avoid excessive re-renders during bursts
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastPathUpdate > 1.0 {
            updatePathInfo()
            updateByteCounters()
            lastPathUpdate = now
        }
    }

    func runThroughputTest(byteCount: Int = 1_000_000) {
        guard !metrics.throughputTestInProgress else { return }
        metrics.throughputTestInProgress = true

        let testID = UUID()
        throughputTestID = testID
        throughputBytesSent = byteCount
        throughputTestStart = Date()

        // Send throughputStart which tells the other side to start timing,
        // then send throughputData messages (properly framed), then the
        // receiver acks with the elapsed time.
        connectionManager.send(.throughputStart(testID: testID, byteCount: byteCount))

        // Send data as framed throughputData messages
        let chunkSize = 32768
        var remaining = byteCount

        Task {
            while remaining > 0 {
                let sendSize = min(chunkSize, remaining)
                connectionManager.send(.throughputData(testID: testID))
                remaining -= sendSize
                try? await Task.sleep(nanoseconds: 500_000) // 0.5ms yield
            }
            // Signal completion
            let elapsed = Date().timeIntervalSince(self.throughputTestStart ?? Date())
            connectionManager.send(.throughputAck(testID: testID, bytesReceived: byteCount, duration: elapsed))
            metrics.throughputBytesPerSec = Double(byteCount) / max(elapsed, 0.001)
            metrics.throughputTestInProgress = false
            throughputTestID = nil
        }
    }

    // MARK: - Private

    private func startPingLoop() {
        pingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sendPing()
            }
        }
    }

    private func sendPing() {
        let id = UUID()
        let timestamp = ProcessInfo.processInfo.systemUptime
        pendingPings[id] = timestamp
        metrics.pingsSent += 1
        connectionManager.send(.ping(id: id, timestamp: timestamp))

        // Count pings older than 3 seconds as lost, then remove them
        let cutoff = timestamp - 3
        let timedOut = pendingPings.filter { $0.value < cutoff }
        if !timedOut.isEmpty {
            metrics.pingsLost += timedOut.count
        }
        pendingPings = pendingPings.filter { $0.value >= cutoff }
    }

    func sendPeerInfo() {
        let device = UIDevice.current
        let name: String = if let custom = UserDefaults.standard.string(forKey: "deviceName"), !custom.isEmpty {
            custom
        } else {
            device.name
        }
        connectionManager.send(.peerInfo(
            deviceName: name,
            osVersion: "\(device.systemName) \(device.systemVersion)",
            model: Self.deviceModelIdentifier()
        ))
    }

    private static func deviceModelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let identifier = withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(validatingUTF8: $0) ?? "Unknown"
            }
        }
        return Self.mapModelName(identifier)
    }

    static func modelName(for identifier: String) -> String {
        mapModelName(identifier)
    }

    private static func mapModelName(_ identifier: String) -> String {
        let mapping: [String: String] = [
            "iPad14,1": "iPad mini (6th gen)",
            "iPad14,2": "iPad mini (6th gen)",
            "iPad14,3": "iPad Pro 11-inch (4th gen)",
            "iPad14,4": "iPad Pro 11-inch (4th gen)",
            "iPad14,5": "iPad Pro 12.9-inch (6th gen)",
            "iPad14,6": "iPad Pro 12.9-inch (6th gen)",
            "iPad14,8": "iPad Air (M2, 11-inch)",
            "iPad14,9": "iPad Air (M2, 11-inch)",
            "iPad14,10": "iPad Air (M2, 13-inch)",
            "iPad14,11": "iPad Air (M2, 13-inch)",
            "iPad13,1": "iPad Air (4th gen)",
            "iPad13,2": "iPad Air (4th gen)",
            "iPad13,4": "iPad Pro 11-inch (3rd gen)",
            "iPad13,5": "iPad Pro 11-inch (3rd gen)",
            "iPad13,6": "iPad Pro 11-inch (3rd gen)",
            "iPad13,7": "iPad Pro 11-inch (3rd gen)",
            "iPad13,8": "iPad Pro 12.9-inch (5th gen)",
            "iPad13,9": "iPad Pro 12.9-inch (5th gen)",
            "iPad13,10": "iPad Pro 12.9-inch (5th gen)",
            "iPad13,11": "iPad Pro 12.9-inch (5th gen)",
            "iPad13,16": "iPad Air (5th gen)",
            "iPad13,17": "iPad Air (5th gen)",
            "iPad13,18": "iPad (10th gen)",
            "iPad13,19": "iPad (10th gen)",
            "iPad16,1": "iPad Pro 11-inch (M4)",
            "iPad16,2": "iPad Pro 11-inch (M4)",
            "iPad16,3": "iPad Pro 13-inch (M4)",
            "iPad16,4": "iPad Pro 13-inch (M4)",
            "iPad16,5": "iPad Air 11-inch (M3)",
            "iPad16,6": "iPad Air 13-inch (M3)",
        ]
        return mapping[identifier] ?? identifier
    }

    private func updatePathInfo() {
        guard let path = connectionManager.currentPath else { return }
        metrics.pathStatus = path.status
        metrics.isExpensive = path.isExpensive
        metrics.isConstrained = path.isConstrained
        if let iface = path.availableInterfaces.first {
            metrics.interfaceType = iface.type
        }
    }

    private func updateByteCounters() {
        metrics.bytesSent = connectionManager.totalBytesSent
        metrics.bytesReceived = connectionManager.totalBytesReceived
    }

    private func startSystemMonitor() {
        systemTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateSystemMetrics()
            }
        }
    }

    private func updateSystemMetrics() {
        let snap = SystemMonitor.snapshot()
        metrics.batteryLevel = snap.batteryLevel
        metrics.batteryState = SystemMonitor.batteryStateString(snap.batteryState)
        metrics.thermalState = SystemMonitor.thermalStateString(snap.thermalState)
        metrics.cpuUsage = snap.cpuUsage
        metrics.memoryUsedMB = snap.memoryUsedMB
        metrics.memoryTotalMB = snap.memoryTotalMB
    }
}
