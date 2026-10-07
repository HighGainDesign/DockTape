// © 2026 High Gain Design. All rights reserved.

import XCTest
@testable import HiDockKit

final class StorageModeTests: XCTestCase {

    func testStorageModeRawValues() {
        XCTAssertEqual(StorageMode.icloud.rawValue, "icloud")
        XCTAssertEqual(StorageMode.local.rawValue, "local")
        XCTAssertEqual(StorageMode.custom.rawValue, "custom")
    }

    func testStorageModeFromString() {
        XCTAssertEqual(StorageMode(rawValue: "icloud"), .icloud)
        XCTAssertEqual(StorageMode(rawValue: "local"), .local)
        XCTAssertEqual(StorageMode(rawValue: "custom"), .custom)
        XCTAssertNil(StorageMode(rawValue: "bogus"))
    }

    func testResolveLocalMode() {
        let url = StorageLocationResolver.resolve(mode: .local, customURL: nil)
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let expected = docs.appendingPathComponent("HiDock Recordings")
        XCTAssertEqual(url, expected)
    }

    func testResolveCustomMode() {
        let custom = URL(fileURLWithPath: "/tmp/my-recordings")
        let url = StorageLocationResolver.resolve(mode: .custom, customURL: custom)
        XCTAssertEqual(url, custom)
    }

    func testResolveCustomModeWithoutURL_FallsBackToLocal() {
        let url = StorageLocationResolver.resolve(mode: .custom, customURL: nil)
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let expected = docs.appendingPathComponent("HiDock Recordings")
        XCTAssertEqual(url, expected)
    }

    func testResolveICloudMode_FallsBackToLocal_WhenUbiquityUnavailable() {
        let url = StorageLocationResolver.resolve(mode: .icloud, customURL: nil, containerURL: { nil })
        XCTAssertEqual(url, StorageLocationResolver.localDefault)
    }

    func testResolveICloudModeUsesAvailableContainerDocuments() {
        let container = URL(fileURLWithPath: "/tmp/icloud-container")
        let url = StorageLocationResolver.resolve(mode: .icloud, customURL: nil, containerURL: { container })
        XCTAssertEqual(url, container.appendingPathComponent("Documents"))
    }

    func testMigrationLogic_ExistingCustomPath() {
        let defaults = UserDefaults(suiteName: "StorageModeTests_custom")!
        defaults.removePersistentDomain(forName: "StorageModeTests_custom")
        defaults.set(URL(fileURLWithPath: "/tmp/custom"), forKey: "libraryLocation")

        let mode = StorageLocationResolver.migratedMode(from: defaults)
        XCTAssertEqual(mode, .custom)
        defaults.removePersistentDomain(forName: "StorageModeTests_custom")
    }

    func testMigrationLogic_NoExistingPath() {
        let defaults = UserDefaults(suiteName: "StorageModeTests_fresh")!
        defaults.removePersistentDomain(forName: "StorageModeTests_fresh")

        let mode = StorageLocationResolver.migratedMode(from: defaults)
        XCTAssertEqual(mode, .icloud)
        defaults.removePersistentDomain(forName: "StorageModeTests_fresh")
    }
}
