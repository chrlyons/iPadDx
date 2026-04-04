import XCTest
@testable import iPadDx

final class iPadCatalogTests: XCTestCase {

    // MARK: - Model name lookup

    func testKnownModelNumbers() {
        XCTAssertEqual(iPadCatalog.modelName(for: "iPad16,5"), "iPad Pro 13-inch (M4)")
        XCTAssertEqual(iPadCatalog.modelName(for: "iPad14,1"), "iPad mini (6th gen)")
        XCTAssertEqual(iPadCatalog.modelName(for: "iPad13,18"), "iPad (10th gen)")
        XCTAssertEqual(iPadCatalog.modelName(for: "iPad15,3"), "iPad Air 11-inch (M3)")
    }

    func testUnknownModelNumberReturnsIdentifier() {
        XCTAssertEqual(iPadCatalog.modelName(for: "iPad99,1"), "iPad99,1")
    }

    // MARK: - Chip family

    func testChipFamilyFromModelName() {
        XCTAssertEqual(iPadCatalog.chipFamily(for: "iPad Pro 13-inch (M4)"), "M4")
        XCTAssertEqual(iPadCatalog.chipFamily(for: "iPad Air 11-inch (M2)"), "M2")
        XCTAssertEqual(iPadCatalog.chipFamily(for: "iPad mini (7th gen)", modelNumber: "iPad16,1"), "A17 Pro")
    }

    func testChipFamilyFromModelNumber() {
        // When model name doesn't contain chip, fall back to catalog lookup by modelNumber
        XCTAssertEqual(iPadCatalog.chipFamily(for: "iPad mini (6th gen)", modelNumber: "iPad14,1"), "A15")
        XCTAssertEqual(iPadCatalog.chipFamily(for: "iPad (10th gen)", modelNumber: "iPad13,18"), "A14")
    }

    func testChipFamilyFromIdentifierAsModelName() {
        // When the model name IS the hardware identifier
        XCTAssertEqual(iPadCatalog.chipFamily(for: "iPad16,3"), "M4")
    }

    func testChipFamilyUnknown() {
        XCTAssertEqual(iPadCatalog.chipFamily(for: "SomeDevice", modelNumber: "Unknown99,1"), "SomeDevice")
        XCTAssertEqual(iPadCatalog.chipFamily(for: "Unknown"), "Unknown")
        XCTAssertEqual(iPadCatalog.chipFamily(for: ""), "Unknown")
    }

    // MARK: - Catalog coverage

    func testAllCatalogEntriesHaveChipAndName() {
        for (identifier, entry) in iPadCatalog.catalog {
            XCTAssertFalse(entry.modelName.isEmpty, "\(identifier) has empty modelName")
            XCTAssertFalse(entry.chip.isEmpty, "\(identifier) has empty chip")
        }
    }

    func testChipPrioritization() {
        // M4 should match before M3, etc.
        XCTAssertEqual(iPadCatalog.chipFamily(for: "iPad with M4 chip"), "M4")
        XCTAssertEqual(iPadCatalog.chipFamily(for: "Something A16 Bionic"), "A16")
    }

    // MARK: - DeviceInfo chip integration

    func testDeviceInfoChipFamily() {
        let info = DeviceInfo(name: "Test", model: "iPad Pro 13-inch (M4)", modelNumber: "iPad16,5", osVersion: "18.0")
        XCTAssertEqual(info.chipFamily, "M4")
    }

    func testDeviceInfoShortDescription() {
        let info = DeviceInfo(name: "Christians iPad", model: "iPad Pro 13-inch (M4)", modelNumber: "iPad16,5", osVersion: "18.0")
        XCTAssertEqual(info.shortDescription, "Christians iPad (M4)")
    }
}
