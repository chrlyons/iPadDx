import CoreLocation
import Foundation
import NetworkExtension
import UIKit

struct WiFiInfo {
    let ssid: String
    let bssid: String
}

struct SystemSnapshot {
    let batteryLevel: Float // 0.0 - 1.0
    let batteryState: UIDevice.BatteryState
    let thermalState: ProcessInfo.ThermalState
    /// 0.0 - 100.0, percent of the whole device's CPU capacity — see
    /// `SystemMonitor.cpuUsageConvention`.
    let cpuUsage: Double
    let memoryUsedMB: Double // this process's physical footprint
    let memoryTotalMB: Double // the device's total RAM
}

enum SystemMonitor {
    /// How every CPU percentage in the app is defined. Show this next to any
    /// CPU number so the reader knows which convention it follows.
    static let cpuUsageConvention = "% of device CPU (all cores)"

    /// CPU below this is comfortable, above `cpuCautionThreshold` is a problem.
    /// Calibrated for the device-wide convention above: a single fully
    /// saturated thread is only ~1/coreCount of the device, so the interesting
    /// range is much lower than the classic per-core-sum numbers.
    static let cpuGoodThreshold: Double = 15
    static let cpuCautionThreshold: Double = 40

    static func enableBatteryMonitoring() {
        UIDevice.current.isBatteryMonitoringEnabled = true
    }

    static func snapshot() -> SystemSnapshot {
        SystemSnapshot(
            batteryLevel: UIDevice.current.batteryLevel,
            batteryState: UIDevice.current.batteryState,
            thermalState: ProcessInfo.processInfo.thermalState,
            cpuUsage: cpuUsage(),
            memoryUsedMB: memoryUsedMB(),
            memoryTotalMB: Double(ProcessInfo.processInfo.physicalMemory) / 1_048_576
        )
    }

    static func batteryLevel() -> Float {
        UIDevice.current.batteryLevel
    }

    static func thermalStateString(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }

    static func batteryStateString(_ state: UIDevice.BatteryState) -> String {
        switch state {
        case .unknown: return "Unknown"
        case .unplugged: return "Unplugged"
        case .charging: return "Charging"
        case .full: return "Full"
        @unknown default: return "Unknown"
        }
    }

    // MARK: - Thermal Transition Tracking

    final class ThermalTracker {
        private var lastState: String = "Nominal"
        private(set) var transitions: [ThermalTransitionRecord] = []

        func reset() {
            lastState = thermalStateString(ProcessInfo.processInfo.thermalState)
            transitions.removeAll()
        }

        func sample() {
            let current = thermalStateString(ProcessInfo.processInfo.thermalState)
            if current != lastState {
                transitions.append(ThermalTransitionRecord(timestamp: Date(), from: lastState, to: current))
                lastState = current
            }
        }
    }

    // MARK: - Wi-Fi Info

    static func currentWiFi() async -> WiFiInfo? {
        await withCheckedContinuation { continuation in
            NEHotspotNetwork.fetchCurrent { network in
                if let network {
                    continuation.resume(returning: WiFiInfo(ssid: network.ssid, bssid: network.bssid))
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - CPU Usage via Mach kernel

    /// This app's CPU usage as a percentage of everything the device can do.
    ///
    /// Convention: **percent of total device capacity, 0–100**. Each thread's
    /// `cpu_usage` is scaled 0…`TH_USAGE_SCALE`, where `TH_USAGE_SCALE` is one
    /// fully saturated core, so summing live threads gives "busy cores"; that
    /// is divided by `activeProcessorCount` to normalize. The alternative
    /// convention (per-core sum, like `top`, where one busy thread reads 100%
    /// and the max is 100 × cores) is deliberately *not* used: a device-wide
    /// percentage stays comparable across chips with different core counts,
    /// which is the entire point of this tool. Every consumer — dashboard
    /// gauges, test reports, responder metrics — reads this same scale.
    private static func cpuUsage() -> Double {
        var threadList: thread_act_array_t?
        var threadCount = mach_msg_type_number_t()

        let result = task_threads(mach_task_self_, &threadList, &threadCount)
        guard result == KERN_SUCCESS, let threads = threadList else { return 0 }

        var busyCores: Double = 0 // 1.0 == one core fully saturated
        let infoSize = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<natural_t>
            .size)

        for i in 0 ..< Int(threadCount) {
            var info = thread_basic_info()
            var infoCount = infoSize

            let kr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) {
                    thread_info(threads[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &infoCount)
                }
            }

            if kr == KERN_SUCCESS, (info.flags & TH_FLAGS_IDLE) == 0 {
                busyCores += Double(info.cpu_usage) / Double(TH_USAGE_SCALE)
            }
        }

        vm_deallocate(
            mach_task_self_,
            vm_address_t(bitPattern: threads),
            vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride)
        )

        // Busy cores -> percent of the whole device
        let coreCount = Double(ProcessInfo.processInfo.activeProcessorCount)
        return min(busyCores / max(coreCount, 1) * 100, 100)
    }

    // MARK: - Memory Usage via Mach kernel

    /// This process's physical footprint in MB. Note this is *not* comparable
    /// to `memoryTotalMB` (the device's whole RAM) as a ratio — they are
    /// different quantities and are labelled separately in the UI.
    private static func memoryUsedMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)

        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }

        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1_048_576
    }
}
