// © 2026 High Gain Design. All rights reserved.
import XCTest
@testable import HiDockKit

final class RecordingFileVersionAccessTests: XCTestCase {
    func testRealFoundationVersionCanBeListedAndReadWithoutReplacingTheCurrentFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("Meeting.transcript.json")
        let prior = root.appendingPathComponent("previous.json")
        let current = Data("{\"text\":\"Current\"}".utf8)
        let old = Data("{\"text\":\"Previous\"}".utf8)
        try current.write(to: original)
        try old.write(to: prior)
        #if os(macOS)
            _ = try await CoordinatedFileAccess().withWrite(at: original) { scope in
                try NSFileVersion.addOfItem(at: scope.url, withContentsOf: prior, options: [])
                return true
            }
        #endif
        let access = RecordingFileVersionAccess()
        let versions = try await access.versions(at: original)
        XCTAssertEqual(versions.count, 1)
        let version = try XCTUnwrap(versions.first)
        XCTAssertEqual(version.id.count, 64, "Opaque identity, not a private version-store path")
        let bytes = try await access.read(version)
        XCTAssertEqual(bytes, old)
        XCTAssertEqual(try Data(contentsOf: original), current)
        let repeated = try await access.versions(at: original)
        XCTAssertEqual(repeated.map(\.id), versions.map(\.id))
    }
    func testCancelledNonlocalMetadataQueryDoesNotWaitForItsProviderCallback() async throws {
        let started = expectation(description: "Provider metadata query started")
        let gate = VersionQueryGate()
        let access = RecordingFileVersionAccess(
            nonlocalQuery: { url, completion in
                Task {
                    await gate.install(completion)
                    started.fulfill()
                }
            }, isUbiquitous: { _ in true })
        let request = Task { try await access.versions(at: URL(fileURLWithPath: "/synthetic/Meeting.transcript.json")) }
        await fulfillment(of: [started], timeout: 1)
        request.cancel()
        do {
            _ = try await request.value
            XCTFail()
        } catch { XCTAssertTrue(error is CancellationError) }
        await gate.complete([])
    }
}
private actor VersionQueryGate {
    var completion: (@Sendable (Result<[RecordingFileVersion], Error>) -> Void)?
    func install(_ completion: @escaping @Sendable (Result<[RecordingFileVersion], Error>) -> Void) {
        self.completion = completion
    }
    func complete(_ versions: [RecordingFileVersion]) {
        completion?(.success(versions))
        completion = nil
    }
}
