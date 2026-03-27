import Foundation
import UIKit

#if canImport(DeviceKit)
    import DeviceKit
#endif

enum DeviceIdentifier {
    // MARK: - Stable Device ID (persisted across launches)

    static var stableID: UUID {
        if let stored = UserDefaults.standard.string(forKey: "stableDeviceID"),
           let uuid = UUID(uuidString: stored)
        {
            return uuid
        }
        let uuid = UUID()
        UserDefaults.standard.set(uuid.uuidString, forKey: "stableDeviceID")
        return uuid
    }

    // MARK: - Hardware Identifier

    static var hardwareIdentifier: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(validatingUTF8: $0) ?? "Unknown"
            }
        }
    }

    // MARK: - Model Name

    static var modelName: String {
        #if canImport(DeviceKit)
            return Device.current.description
        #else
            return iPadCatalog.modelName(for: hardwareIdentifier)
        #endif
    }

    // MARK: - Chip Family (runtime detection via sysctl)

    static var chipFamily: String {
        // Try sysctl hw.cpufamily first — works without any lookup table
        if let chip = chipFromSysctl() {
            return chip
        }
        // Fallback to catalog lookup
        return iPadCatalog.chipFamily(for: modelName, modelNumber: hardwareIdentifier)
    }

    // MARK: - Full DeviceInfo

    static func localDeviceInfo(name: String? = nil) -> DeviceInfo {
        let deviceName: String = if let custom = name ?? UserDefaults.standard.string(forKey: "deviceName"),
                                    !custom.isEmpty
        {
            custom
        } else {
            UIDevice.current.name
        }
        return DeviceInfo(
            name: deviceName,
            model: modelName,
            modelNumber: hardwareIdentifier,
            osVersion: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        )
    }

    // MARK: - sysctl chip detection

    private static func chipFromSysctl() -> String? {
        var size: size_t = 0
        sysctlbyname("hw.cpufamily", nil, &size, nil, 0)
        guard size > 0 else { return nil }

        var cpuFamily: UInt32 = 0
        var cpuSize = MemoryLayout<UInt32>.size
        sysctlbyname("hw.cpufamily", &cpuFamily, &cpuSize, nil, 0)

        // Also get the CPU subtype for more detail
        var cpuSubtype: UInt32 = 0
        var subtypeSize = MemoryLayout<UInt32>.size
        sysctlbyname("hw.cpusubtype", &cpuSubtype, &subtypeSize, nil, 0)

        // Map known cpufamily values to chip names
        // These are CPUFAMILY_ARM_* constants from <mach/machine.h>
        let familyMap: [UInt32: String] = [
            // A12
            0x07D3_4335: "A12",
            // A13
            0x462F_04AA: "A13",
            // A14
            0x1B58_8161: "A14",
            // A15
            0xDA33_D83D: "A15",
            // A16
            0xFA33_D415: "A16",
            // A17 Pro
            0x7201_5BDA: "A17 Pro",
            // M1
            0x1CF2_EF2D: "M1",
            // M2
            0x573B_559F: "M2",
            // M3
            0x5F4D_EA93: "M3",
            // M4
            0x72C4_868A: "M4",
        ]

        if let chip = familyMap[cpuFamily] {
            return chip
        }

        // Unrecognized CPU family — return nil so the catalog lookup
        // (based on hardware model number) gets used as fallback
        return nil
    }
}
