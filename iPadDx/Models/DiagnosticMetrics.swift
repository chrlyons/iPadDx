import Foundation
import Network

enum SignalQuality: String, CaseIterable {
    case excellent = "Excellent"
    case good = "Good"
    case fair = "Fair"
    case poor = "Poor"

    var color: String {
        switch self {
        case .excellent: "green"
        case .good: "blue"
        case .fair: "orange"
        case .poor: "red"
        }
    }
}

struct LatencySample: Identifiable {
    let id: Int
    let value: Double
}

struct ConnectionEvent: Identifiable {
    let id = UUID()
    let timestamp: Date
    let event: String
}

enum ConnectionState: String {
    case discovered = "Discovered"
    case connecting = "Connecting"
    case connected = "Connected"
    case failed = "Failed"
    case disconnected = "Disconnected"
}

@Observable
class DiagnosticMetrics {
    // Latency
    var latencyMs: Double = 0
    var latencyHistory: [LatencySample] = []
    private var sampleCounter: Int = 0

    // Throughput
    var throughputBytesPerSec: Double?
    var throughputTestInProgress: Bool = false

    // Connection
    var connectionStartTime: Date?
    var disconnectionCount: Int = 0
    var connectionLog: [ConnectionEvent] = []

    // Packet loss
    var pingsSent: Int = 0
    var pongsReceived: Int = 0
    var pingsLost: Int = 0

    // Data transfer
    var bytesSent: Int = 0
    var bytesReceived: Int = 0

    // Network path
    var pathStatus: NWPath.Status = .unsatisfied
    var interfaceType: NWInterface.InterfaceType?
    var isExpensive: Bool = false
    var isConstrained: Bool = false

    // Peer info
    var peerDeviceName: String?
    var peerOSVersion: String?
    var peerModel: String?
    var peerModelNumber: String?
    var peerSSID: String?
    var peerBSSID: String?

    // System
    var batteryLevel: Float = -1 // 0.0–1.0, -1 = unknown
    var batteryState: String = "Unknown"
    var thermalState: String = "Nominal"
    var cpuUsage: Double = 0 // 0–100%
    var memoryUsedMB: Double = 0
    var memoryTotalMB: Double = 0
    var batteryAtConnectionStart: Float = -1

    func appendLatency(_ rtt: Double, maxHistory: Int = 120) {
        sampleCounter += 1
        latencyHistory.append(LatencySample(id: sampleCounter, value: rtt))
        if latencyHistory.count > maxHistory {
            latencyHistory.removeFirst(latencyHistory.count - maxHistory)
        }
    }

    func logEvent(_ event: String) {
        connectionLog.insert(ConnectionEvent(timestamp: Date(), event: event), at: 0)
        if connectionLog.count > 50 {
            connectionLog.removeLast()
        }
    }

    // MARK: - Computed

    var signalQuality: SignalQuality {
        guard latencyHistory.count >= 5 else { return .poor }
        let recent = latencyHistory.suffix(30).map(\.value)
        let mean = recent.reduce(0, +) / Double(recent.count)
        let variance = recent.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(recent.count)
        let stddev = variance.squareRoot()

        if mean < 10, stddev < 3 { return .excellent }
        if mean < 30, stddev < 10 { return .good }
        if mean < 100, stddev < 30 { return .fair }
        return .poor
    }

    var packetLossPercent: Double {
        let resolved = pongsReceived + pingsLost
        guard resolved > 0 else { return 0 }
        return Double(pingsLost) / Double(resolved) * 100
    }

    var jitterMs: Double {
        let values = latencyHistory.suffix(30).map(\.value)
        guard values.count >= 2 else { return 0 }
        var diffs: [Double] = []
        for i in 1 ..< values.count {
            diffs.append(abs(values[i] - values[i - 1]))
        }
        return diffs.reduce(0, +) / Double(diffs.count)
    }

    var latencyMin: Double {
        latencyHistory.map(\.value).min() ?? 0
    }

    var latencyMax: Double {
        latencyHistory.map(\.value).max() ?? 0
    }

    var latencyAvg: Double {
        guard !latencyHistory.isEmpty else { return 0 }
        return latencyHistory.map(\.value).reduce(0, +) / Double(latencyHistory.count)
    }

    var connectionUptime: TimeInterval {
        guard let start = connectionStartTime else { return 0 }
        return Date().timeIntervalSince(start)
    }

    var formattedUptime: String {
        let total = Int(connectionUptime)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%dh %02dm %02ds", hours, minutes, seconds)
        }
        return String(format: "%dm %02ds", minutes, seconds)
    }

    var interfaceTypeString: String {
        guard let type = interfaceType else { return "Unknown" }
        switch type {
        case .wifi: return "Wi-Fi"
        case .cellular: return "Cellular"
        case .wiredEthernet: return "Ethernet"
        case .loopback: return "Loopback"
        case .other: return "Other"
        @unknown default: return "Unknown"
        }
    }

    var formattedThroughput: String {
        guard let bps = throughputBytesPerSec else { return "Not tested" }
        if bps >= 1_000_000 {
            return String(format: "%.1f MB/s", bps / 1_000_000)
        } else if bps >= 1000 {
            return String(format: "%.1f KB/s", bps / 1000)
        }
        return String(format: "%.0f B/s", bps)
    }

    var formattedBytesSent: String {
        formatBytes(bytesSent)
    }

    var formattedBytesReceived: String {
        formatBytes(bytesReceived)
    }

    var batteryPercent: String {
        guard batteryLevel >= 0 else { return "N/A" }
        return "\(Int(batteryLevel * 100))%"
    }

    var batteryDrain: String {
        guard batteryAtConnectionStart >= 0, batteryLevel >= 0 else { return "N/A" }
        let drain = batteryAtConnectionStart - batteryLevel
        if drain <= 0 { return "<1% (too short to measure)" }
        return String(format: "%.1f%%", drain * 100)
    }

    var formattedMemory: String {
        String(format: "%.0f / %.0f MB", memoryUsedMB, memoryTotalMB)
    }

    private func formatBytes(_ bytes: Int) -> String {
        if bytes >= 1_000_000 {
            return String(format: "%.1f MB", Double(bytes) / 1_000_000)
        } else if bytes >= 1000 {
            return String(format: "%.1f KB", Double(bytes) / 1000)
        }
        return "\(bytes) B"
    }
}
