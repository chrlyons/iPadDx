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

    // MARK: - Chip Family

    /// The hardware model identifier (`iPad14,3`) is the authoritative source:
    /// it names the exact product, and `iPadCatalog` maps it to the exact chip.
    ///
    /// `hw.cpufamily` names the *CPU core family*, not the chip — A14 and M1
    /// share one value (Firestorm/Icestorm) and A15 and M2 share another
    /// (Avalanche/Blizzard), so sysctl physically cannot tell those apart.
    /// It is therefore only consulted for hardware the catalog doesn't know
    /// yet, and for the ambiguous families it reports the shared label rather
    /// than guessing one of the two chips.
    static var chipFamily: String {
        if let entry = iPadCatalog.catalog[hardwareIdentifier] {
            return entry.chip
        }
        if let chip = chipFromSysctl() {
            return chip
        }
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

    // MARK: - sysctl chip detection (fallback only)

    /// `CPUFAMILY_ARM_*` constants from `<mach/machine.h>`, keyed by the value
    /// `hw.cpufamily` reports. Two of these core families ship in more than one
    /// chip, so their label names both — sysctl has no way to narrow it down.
    private static let cpuFamilyNames: [UInt32: String] = [
        0x07D3_4B9F: "A12", // Vortex/Tempest
        0x4625_04D2: "A13", // Lightning/Thunder
        0x1B58_8BB3: "A14/M1", // Firestorm/Icestorm — A14 and M1 are identical here
        0xDA33_D83D: "A15/M2", // Avalanche/Blizzard — A15 and M2 are identical here
        0x8765_EDEA: "A16", // Everest/Sawtooth
        0x2876_F5B5: "A17 Pro", // Coll
        0xFA33_415E: "M3", // Ibiza
        0x17D5_B93A: "M4", // Palma
    ]

    private static func chipFromSysctl() -> String? {
        var size: size_t = 0
        sysctlbyname("hw.cpufamily", nil, &size, nil, 0)
        guard size > 0 else { return nil }

        var cpuFamily: UInt32 = 0
        var cpuSize = MemoryLayout<UInt32>.size
        sysctlbyname("hw.cpufamily", &cpuFamily, &cpuSize, nil, 0)

        // An unrecognized family yields nil, so the caller falls back to the
        // model-name catalog lookup rather than inventing a chip name.
        return cpuFamilyNames[cpuFamily]
    }
}
