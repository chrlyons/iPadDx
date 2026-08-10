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

// MARK: - Disconnect Reason (Feature #2)

enum DisconnectReason: String, Codable {
    case userInitiated, remoteDisconnect, keepaliveTimeout
    case pathChanged, tlsError, connectionRefused, networkError, unknown
}

struct DisconnectEvent: Identifiable {
    let id = UUID()
    let timestamp: Date
    let reason: DisconnectReason
    let detail: String
    let uptimeAtDisconnect: TimeInterval
}

// MARK: - Latency Anomaly (Feature #10)

enum AnomalySeverity: String { case warning, critical }

struct LatencyAnomaly: Identifiable {
    let id: Int
    let value: Double
    let mean: Double
    let threshold: Double
    let severity: AnomalySeverity
}

// MARK: - Remote Metrics (Feature #5)

struct RemoteMetricsSample: Identifiable {
    let id = UUID()
    let timestamp: Date
    let cpu: Double
    let memoryMB: Double
    let thermalState: String
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
    var disconnectHistory: [DisconnectEvent] = []
    var anomalies: [LatencyAnomaly] = []
    var remoteMetricsHistory: [RemoteMetricsSample] = []

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
        checkForAnomaly(rtt)
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

    func logDisconnect(reason: DisconnectReason, detail: String = "") {
        disconnectionCount += 1
        disconnectHistory.append(DisconnectEvent(
            timestamp: Date(), reason: reason, detail: detail, uptimeAtDisconnect: connectionUptime
        ))
        // Bounded like connectionLog / anomalies — a flapping link over a long
        // soak run would otherwise grow this forever. `disconnectionCount`
        // above stays the authoritative total, so nothing is under-reported.
        if disconnectHistory.count > 50 {
            disconnectHistory.removeFirst()
        }
        logEvent("Disconnected: \(reason.rawValue)\(detail.isEmpty ? "" : " — \(detail)")")
    }

    func appendRemoteMetrics(cpu: Double, memoryMB: Double, thermalState: String) {
        remoteMetricsHistory.append(RemoteMetricsSample(
            timestamp: Date(), cpu: cpu, memoryMB: memoryMB, thermalState: thermalState
        ))
        if remoteMetricsHistory.count > 100 {
            remoteMetricsHistory.removeFirst()
        }
    }

    private func checkForAnomaly(_ sample: Double) {
        // Baseline excludes the candidate itself — including it drags the mean
        // toward the spike and inflates the stddev, which hides real anomalies
        // when only a handful of samples have been collected.
        let recent = latencyHistory.dropLast().suffix(30).map(\.value)
        guard recent.count >= 10 else { return }
        let mean = recent.reduce(0, +) / Double(recent.count)
        let stddev = (recent.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(recent.count)).squareRoot()
        guard stddev > 0.5 else { return }
        if sample > mean + 3 * stddev {
            anomalies.append(LatencyAnomaly(
                id: sampleCounter, value: sample, mean: mean, threshold: mean + 3 * stddev,
                severity: sample > mean + 5 * stddev ? .critical : .warning
            ))
            if anomalies.count > 50 {
                anomalies.removeFirst()
            }
        }
    }

    // MARK: - Computed

    /// Live connection quality across every dimension the model measures:
    /// latency, stability (stddev of the recent window), jitter and packet
    /// loss. Each dimension is graded on its own and the *worst* one wins — a
    /// link is only as good as its weakest property, and a 2ms link that drops
    /// 5% of pings is not "Excellent".
    ///
    /// Load degradation is the fifth dimension the README mentions; it is only
    /// measurable by the test suite (baseline vs under-load), so it is graded
    /// in the report, not here.
    var signalQuality: SignalQuality {
        guard latencyHistory.count >= 5 else { return .poor }
        let recent = latencyHistory.suffix(30).map(\.value)
        let mean = recent.reduce(0, +) / Double(recent.count)
        let variance = recent.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(recent.count)
        let stddev = variance.squareRoot()

        var tiers = [
            qualityTier(mean, excellent: 10, good: 30, fair: 100), // latency
            qualityTier(stddev, excellent: 3, good: 10, fair: 30), // stability
            qualityTier(jitterMs, excellent: 3, good: 10, fair: 30), // jitter
        ]
        // Packet loss only counts once enough pings have resolved for the
        // percentage to mean something — one lost ping out of five is 20%,
        // which would swamp the grade on noise.
        if pongsReceived + pingsLost >= 20 {
            tiers.append(qualityTier(packetLossPercent, excellent: 0.5, good: 2, fair: 5))
        }

        let ranked: [SignalQuality] = [.excellent, .good, .fair, .poor]
        return ranked[tiers.max() ?? ranked.count - 1]
    }

    /// Bucket a lower-is-better metric into a quality tier:
    /// 0 = excellent, 1 = good, 2 = fair, 3 = poor.
    private func qualityTier(_ value: Double, excellent: Double, good: Double, fair: Double) -> Int {
        if value < excellent {
            return 0
        }
        if value < good {
            return 1
        }
        if value < fair {
            return 2
        }
        return 3
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
        if drain <= 0 {
            return "<1% (too short to measure)"
        }
        return String(format: "%.1f%%", drain * 100)
    }

    /// App footprint and device RAM are different quantities — this app's
    /// `phys_footprint` versus the whole device's memory — so they are labelled
    /// separately instead of being rendered as a "used / total" ratio.
    var formattedMemory: String {
        guard memoryTotalMB > 0 else {
            return String(format: "%.0f MB app footprint", memoryUsedMB)
        }
        return String(format: "%.0f MB app · %.0f MB device RAM", memoryUsedMB, memoryTotalMB)
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
