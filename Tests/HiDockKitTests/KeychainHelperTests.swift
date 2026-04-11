// © 2026 High Gain Design. All rights reserved.

// Tests/HiDockKitTests/KeychainHelperTests.swift
import XCTest
@testable import HiDockKit

final class KeychainHelperTests: XCTestCase {
    let service = "com.docktape.tests.keychain-\(UUID().uuidString)"

    override func tearDown() {
        // Clean up any test keys
        KeychainHelper.delete(service: service, account: "testkey")
        KeychainHelper.delete(service: service, account: "overwrite")
    }

    func testSaveAndRead() throws {
        try KeychainHelper.save(key: "sk-test-12345", service: service, account: "testkey")
        let read = KeychainHelper.read(service: service, account: "testkey")
        XCTAssertEqual(read, "sk-test-12345")
    }

    func testReadMissing() {
        let read = KeychainHelper.read(service: service, account: "nonexistent")
        XCTAssertNil(read)
    }

    func testOverwrite() throws {
        try KeychainHelper.save(key: "first", service: service, account: "overwrite")
        try KeychainHelper.save(key: "second", service: service, account: "overwrite")
        let read = KeychainHelper.read(service: service, account: "overwrite")
        XCTAssertEqual(read, "second")
    }

    func testDelete() throws {
        try KeychainHelper.save(key: "deleteme", service: service, account: "testkey")
        KeychainHelper.delete(service: service, account: "testkey")
        let read = KeychainHelper.read(service: service, account: "testkey")
        XCTAssertNil(read)
    }
}
