import Foundation
import UIKit

struct SystemSnapshot {
    let batteryLevel: Float // 0.0 - 1.0
    let batteryState: UIDevice.BatteryState
    let thermalState: ProcessInfo.ThermalState
    let cpuUsage: Double // 0.0 - 100.0
    let memoryUsedMB: Double
    let memoryTotalMB: Double
}

enum SystemMonitor {
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

    // MARK: - CPU Usage via Mach kernel

    private static func cpuUsage() -> Double {
        var threadList: thread_act_array_t?
        var threadCount = mach_msg_type_number_t()

        let result = task_threads(mach_task_self_, &threadList, &threadCount)
        guard result == KERN_SUCCESS, let threads = threadList else { return 0 }

        var totalUsage: Double = 0
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
                totalUsage += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100
            }
        }

        vm_deallocate(
            mach_task_self_,
            vm_address_t(bitPattern: threads),
            vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride)
        )

        // Normalize to 0-100% by dividing by number of active CPU cores
        let coreCount = Double(ProcessInfo.processInfo.activeProcessorCount)
        return min(totalUsage / max(coreCount, 1), 100)
    }

    // MARK: - Memory Usage via Mach kernel

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
