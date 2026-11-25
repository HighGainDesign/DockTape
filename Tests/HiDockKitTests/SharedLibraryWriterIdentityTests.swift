// © 2026 High Gain Design. All rights reserved.
import XCTest
@testable import HiDockKit

final class SharedLibraryWriterIdentityTests: XCTestCase {
    func testRestartSharesWriterButAClonedOrRestoredInstallationRotatesIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("writer.json")
        let first = try await SharedLibraryWriterIdentityStore(file: file, installationAnchor: "host-A/device-only-key-A").load()
        let restarted = try await SharedLibraryWriterIdentityStore(file: file, installationAnchor: "host-A/device-only-key-A").load()
        XCTAssertEqual(first, restarted)
        let clone = try await SharedLibraryWriterIdentityStore(file: file, installationAnchor: "host-B/device-only-key-B").load()
        XCTAssertNotEqual(clone.writer, first.writer)
        XCTAssertNotEqual(clone.requestID, first.requestID)
        let restored = try await SharedLibraryWriterIdentityStore(file: file, installationAnchor: "host-B/device-only-key-C").load()
        XCTAssertNotEqual(restored.writer, clone.writer)
        let bytes = try Data(contentsOf: file)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("host-B"), "Do not persist the anchor in clear text")
    }
    func testConcurrentSameMacProcessesUseOneIdentityAndCorruptionNeverInventsANewWriter() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("writer.json")
        async let one = SharedLibraryWriterIdentityStore(file: file, installationAnchor: "local-device-key").load()
        async let two = SharedLibraryWriterIdentityStore(file: file, installationAnchor: "local-device-key").load()
        let results = try await (one,two)
        XCTAssertEqual(results.0, results.1)
        let bytes = Data("corrupt identity".utf8)
        try bytes.write(to: file)
        do { _ = try await SharedLibraryWriterIdentityStore(file: file, installationAnchor: "local-device-key").load(); XCTFail() }
        catch { XCTAssertTrue(error is DecodingError) }
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }
}
