// © 2026 High Gain Design. All rights reserved.
import XCTest

@testable import HiDockKit

final class SharedWriterIdentityFactoryTests: XCTestCase {
  func testFactoryUsesLocalBackupExcludedIdentityAndRotatesOnDifferentDeviceNonce() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let first = SharedWriterIdentityFactory(
      directory: root, hardware: { "fixture-device-A" }, nonce: { Data(repeating: 1, count: 32) })
    let a = try await first.load()
    let restarted = try await first.load()
    XCTAssertEqual(a, restarted)
    let clone = SharedWriterIdentityFactory(
      directory: root, hardware: { "fixture-device-B" }, nonce: { Data(repeating: 2, count: 32) })
    let b = try await clone.load()
    XCTAssertNotEqual(a.writer, b.writer)
    let file = root.appendingPathComponent("writer.json")
    let text = try String(contentsOf: file)
    XCTAssertFalse(text.contains("fixture-device"))
    var current = file
    current.removeAllCachedResourceValues()
    XCTAssertEqual(
      try current.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
  }
  func testMissingPlatformAnchorNeverCreatesAWriterFile() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let factory = SharedWriterIdentityFactory(
      directory: root, hardware: { "" }, nonce: { Data(repeating: 1, count: 32) })
    do {
      _ = try await factory.load()
      XCTFail()
    } catch {}
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("writer.json").path))
  }
}
