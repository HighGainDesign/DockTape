// © 2026 High Gain Design. All rights reserved.
import XCTest
@testable import HiDockKit

final class ProviderFileAccessTests: XCTestCase {
    private actor Gate {
        var ready = false
        func wait() async throws { while !ready { try await Task.sleep(for: .milliseconds(10)) } }
        func release() { ready = true }
    }
    func testProviderPreparationUsesCoordinationWithoutCallingICloudDownload() async throws {
        let started = expectation(description: "File Provider preparation")
        let waiting = expectation(description: "Waiting visible")
        let access = RecordingFileAccess(
            availability: { .providerManaged($0) },
            requestDownload: { _ in XCTFail("Dropbox must not call the iCloud download API") },
            prepareProvider: { _ in started.fulfill() }, readFile: { _ in Data("ready".utf8) })
        let bytes = try await access.readDataIfPresent(
            at: URL(fileURLWithPath: "/provider/audio.mp3"), onWaiting: { waiting.fulfill() })
        await fulfillment(of: [started, waiting], timeout: 1)
        XCTAssertEqual(bytes, Data("ready".utf8))
    }
    func testProviderAWaitDoesNotBlockResidentBAndCancelNeverReadsALater() async throws {
        let gate = Gate()
        let started = expectation(description: "A preparing")
        let readA = expectation(description: "Canceled A never reads")
        readA.isInverted = true
        let access = RecordingFileAccess(
            availability: { url in url.lastPathComponent == "a.mp3" ? .providerManaged(url) : .local },
            requestDownload: { _ in XCTFail() },
            prepareProvider: { _ in
                started.fulfill()
                try await gate.wait()
            },
            readFile: { url in
                if url.lastPathComponent == "a.mp3" { readA.fulfill() }
                return Data(url.lastPathComponent.utf8)
            })
        let a = Task { try await access.readDataIfPresent(at: URL(fileURLWithPath: "/provider/a.mp3")) }
        await fulfillment(of: [started], timeout: 1)
        let b = try await access.readDataIfPresent(at: URL(fileURLWithPath: "/provider/b.mp3"))
        XCTAssertEqual(b, Data("b.mp3".utf8))
        a.cancel()
        do {
            _ = try await a.value
            XCTFail()
        } catch { XCTAssertTrue(error is CancellationError) }
        await gate.release()
        await fulfillment(of: [readA], timeout: 0.05)
    }
    func testProviderStoppedPermissionFailureAndTimeoutRemainErrorsNotMissingOrCorrupt() async throws {
        let access = RecordingFileAccess(
            availability: { .providerManaged($0) }, requestDownload: { _ in XCTFail() },
            prepareProvider: { _ in throw CocoaError(.fileReadNoPermission) })
        do {
            _ = try await access.readDataIfPresent(at: URL(fileURLWithPath: "/provider/a.json"))
            XCTFail()
        } catch { XCTAssertEqual((error as NSError).code, CocoaError.fileReadNoPermission.rawValue) }
        let gate = Gate()
        let stalled = RecordingFileAccess(
            availability: { .providerManaged($0) }, requestDownload: { _ in XCTFail() },
            timeout: .milliseconds(20), prepareProvider: { _ in try await gate.wait() })
        do {
            _ = try await stalled.readDataIfPresent(at: URL(fileURLWithPath: "/provider/a.json"))
            XCTFail()
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("storage provider"))
            XCTAssertFalse(error.localizedDescription.contains("iCloud"))
        }
    }
    func testKnownMissingProviderPreparationHonorsTimeoutDuringCoordination() async throws {
        let gate = Gate()
        let release = Task {
            try await Task.sleep(for: .milliseconds(500))
            await gate.release()
        }
        defer { release.cancel() }
        let access = RecordingFileAccess(
            availability: { _ in .missing },
            requestDownload: { _ in try await gate.wait() }, timeout: .milliseconds(20))
        let start = ContinuousClock.now
        do {
            _ = try await access.readDataIfPresent(
                at: URL(fileURLWithPath: "/provider/a.json"), knownToExist: true)
            XCTFail("A stalled provider must return its timeout")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("storage provider"))
        }
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(400))
    }

    func testSelfCancelledRequestDoesNotInvokeProviderOrReadBytes() async throws {
        let access = RecordingFileAccess(
            availability: { _ in
                XCTFail()
                return .local
            }, requestDownload: { _ in XCTFail() },
            prepareProvider: { _ in XCTFail() },
            readFile: { _ in
                XCTFail()
                return Data()
            })
        let request = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await access.readDataIfPresent(at: URL(fileURLWithPath: "/provider/a.json"))
        }
        do {
            _ = try await request.value
            XCTFail()
        } catch { XCTAssertTrue(error is CancellationError) }
    }
    func testRealResidentFileReadsAndMissingUnannouncedFileStaysAbsent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a.json")
        let bytes = Data("resident".utf8)
        try bytes.write(to: file)
        let access = RecordingFileAccess()
        let current = try await access.readDataIfPresent(at: file)
        XCTAssertEqual(current, bytes)
        let missing = try await access.readDataIfPresent(at: root.appendingPathComponent("not-created.json"))
        XCTAssertNil(missing)
    }
    func testResidentEmptyAndSparseFilesAreNotClassifiedAsProviderPlaceholders() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = root.appendingPathComponent("empty.mp3")
        let sparse = root.appendingPathComponent("sparse.mp3")
        try Data().write(to: empty)
        try Data().write(to: sparse)
        let file = try FileHandle(forWritingTo: sparse)
        try file.truncate(atOffset: 8192)
        try file.close()
        XCTAssertFalse(RecordingFileAccess.isDataless(empty))
        XCTAssertFalse(RecordingFileAccess.isDataless(sparse))
        let waiting = expectation(description: "Resident metadata must not request cloud hydration")
        waiting.isInverted = true
        let access = RecordingFileAccess()
        let bytes = try await access.readDataIfPresent(at: sparse, onWaiting: { waiting.fulfill() })
        XCTAssertEqual(bytes?.count, 8192)
        await fulfillment(of: [waiting], timeout: 0.05)
        let names = Set(LibraryFileDiscovery.files(in: root, suffix: ".mp3").map(\.logicalName))
        XCTAssertEqual(names, ["empty.mp3", "sparse.mp3"])
    }

    func testKnownMetadataGapWaitsWithoutClassifyingAbsenceAsCorruption() async throws {
        actor Steps {
            var count = 0
            func next(_ url: URL) -> RecordingFileAccess.Availability {
                count += 1
                return count == 1 ? .missing : .providerManaged(url)
            }
        }
        let steps = Steps()
        let requested = expectation(description: "Expected metadata gap")
        let prepared = expectation(description: "Provider reached")
        let access = RecordingFileAccess(
            availability: { await steps.next($0) }, requestDownload: { _ in requested.fulfill() },
            prepareProvider: { _ in prepared.fulfill() }, readFile: { _ in Data("available".utf8) })
        let result = try await access.readDataIfPresent(
            at: URL(fileURLWithPath: "/provider/a.json"), knownToExist: true)
        await fulfillment(of: [requested, prepared], timeout: 1)
        XCTAssertEqual(result, Data("available".utf8))
    }
}
