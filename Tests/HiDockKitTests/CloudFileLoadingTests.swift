// © 2026 High Gain Design. All rights reserved.
import XCTest
@testable import HiDockKit

final class CloudFileLoadingTests: XCTestCase {
    private actor Gate {
        var ready = false
        var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if ready { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func release() { ready = true; waiters.forEach { $0.resume() }; waiters.removeAll() }
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func transcript(_ file: String) -> Transcript {
        Transcript(recordingFilename: file, transcriptionModel: "test", hasSpeakerLabels: false,
                   segments: [.init(startTime: 0, endTime: 1, text: file)])
    }

    private func summary(_ file: String, text: String = "Ready summary") -> Summary {
        Summary(recordingFilename: file, model: "test", provider: "test", templateUsed: "meeting",
                sections: [.init(heading: "Summary", content: text)])
    }

    func testCloudWaitIsCancellableAndDoesNotReadMissingBytes() async throws {
        let started = expectation(description: "Download requested")
        let read = expectation(description: "Pending cloud file must not be read")
        read.isInverted = true
        let access = RecordingFileAccess(availability: { .downloading($0) },
            requestDownload: { _ in started.fulfill() }, readFile: { _ in read.fulfill(); return Data() })
        let task = Task { try await access.readDataIfPresent(at: URL(fileURLWithPath: "/pending.json")) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation should exit the wait") }
        catch { XCTAssertTrue(error is CancellationError) }
        await fulfillment(of: [read], timeout: 0.05)
    }

    func testCloudWaitLoadsOnceBytesBecomeAvailable() async throws {
        let gate = Gate()
        let started = expectation(description: "Waiting for iCloud")
        let access = RecordingFileAccess(availability: { url in
            await gate.ready ? .local : .downloading(url)
        }, requestDownload: { _ in await gate.release() }, readFile: { _ in Data("ready".utf8) })
        let data = try await access.readDataIfPresent(at: URL(fileURLWithPath: "/cloud.json"),
                                                     onWaiting: { started.fulfill() })
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(data, Data("ready".utf8))
    }

    func testPlaceholderTransitionDoesNotBecomeMissingContent() async throws {
        actor Steps {
            var count = 0
            func next(_ url: URL) -> RecordingFileAccess.Availability {
                count += 1
                if count == 1 { return .downloading(url) }
                if count == 2 { return .missing }
                return .local
            }
        }
        let steps = Steps()
        let access = RecordingFileAccess(availability: { await steps.next($0) },
            requestDownload: { _ in }, readFile: { _ in Data("hydrated".utf8) })
        let data = try await access.readDataIfPresent(at: URL(fileURLWithPath: "/cloud.json"))
        XCTAssertEqual(data, Data("hydrated".utf8))
    }

    func testKnownSummaryWaitsThroughInitiallyInvisiblePlaceholder() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let writer = SummaryStore(baseDirectory: dir)
        try await writer.save(summary("a.mp3"), mp3Filename: "a.mp3")
        actor Steps {
            var first = true
            func next() -> RecordingFileAccess.Availability {
                if first { first = false; return .missing }
                return .local
            }
        }
        let steps = Steps()
        let requested = expectation(description: "Known file requested despite metadata gap")
        let access = RecordingFileAccess(availability: { _ in await steps.next() },
                                          requestDownload: { _ in requested.fulfill() })
        let store = SummaryStore(baseDirectory: dir, fileAccess: access)
        try await store.loadAll()
        let loaded = try await store.loadSummary(for: "a.mp3")
        await fulfillment(of: [requested], timeout: 2)
        XCTAssertEqual(loaded?.recordingFilename, "a.mp3")
    }

    func testLateMissingLookupCannotHideNewlySavedSummary() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let gate = Gate(), started = expectation(description: "Old missing lookup pending")
        let access = RecordingFileAccess(availability: { _ in
            started.fulfill(); await gate.wait(); return .missing
        }, requestDownload: { _ in XCTFail() })
        let store = SummaryStore(baseDirectory: dir, fileAccess: access)
        let pending = Task { try await store.loadSummary(for: "a.mp3") }
        await fulfillment(of: [started], timeout: 2)
        try await store.save(summary("a.mp3", text: "New"), mp3Filename: "a.mp3")
        await gate.release()
        let result = try await pending.value
        XCTAssertEqual(result?.sections.first?.content, "New")
    }

    func testMissingAndDownloadFailureAreDifferent() async throws {
        let missing = RecordingFileAccess(availability: { _ in .missing }, requestDownload: { _ in XCTFail() })
        let absent = try await missing.readDataIfPresent(at: URL(fileURLWithPath: "/missing.json"))
        XCTAssertNil(absent)
        let failed = RecordingFileAccess(availability: { .downloading($0) },
            requestDownload: { _ in throw CocoaError(.fileReadNoPermission) })
        do { _ = try await failed.readDataIfPresent(at: URL(fileURLWithPath: "/cloud.json")); XCTFail() }
        catch { XCTAssertEqual((error as NSError).code, CocoaError.fileReadNoPermission.rawValue) }
    }

    func testCloudWaitTimesOutWithUsefulError() async throws {
        let access = RecordingFileAccess(availability: { .downloading($0) }, requestDownload: { _ in }, timeout: .zero)
        do { _ = try await access.readDataIfPresent(at: URL(fileURLWithPath: "/cloud.json")); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("iCloud Drive")) }
    }

    func testResidentTranscriptLoadsWhileAnotherDiskReadIsPending() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let writer = TranscriptStore(baseDirectory: dir)
        try await writer.save(transcript("a.mp3"), mp3Filename: "a.mp3")
        try await writer.save(transcript("b.mp3"), mp3Filename: "b.mp3")
        let gate = Gate(), started = expectation(description: "A read pending"), bReady = expectation(description: "B independent")
        let access = RecordingFileAccess(availability: { _ in .local }, requestDownload: { _ in }, readFile: { url in
            if url.lastPathComponent == "a.transcript.json" { started.fulfill(); await gate.wait() }
            return try Data(contentsOf: url)
        })
        let store = TranscriptStore(baseDirectory: dir, fileAccess: access)
        let a = Task { try await store.loadTranscript(for: "a.mp3") }
        await fulfillment(of: [started], timeout: 2)
        let b = Task { let value = try await store.loadTranscript(for: "b.mp3"); bReady.fulfill(); return value }
        await fulfillment(of: [bReady], timeout: 2)
        // Always release A after the bounded independence assertion, even on failure.
        await gate.release()
        let loadedB = try await b.value
        XCTAssertEqual(loadedB?.recordingFilename, "b.mp3")
        await gate.release(); _ = try await a.value
    }

    func testResidentSummaryLoadsWhileAnotherDiskReadIsPending() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let writer = SummaryStore(baseDirectory: dir)
        try await writer.save(summary("a.mp3"), mp3Filename: "a.mp3")
        try await writer.save(summary("b.mp3"), mp3Filename: "b.mp3")
        let gate = Gate(), started = expectation(description: "A read pending"), bReady = expectation(description: "B independent")
        let access = RecordingFileAccess(availability: { _ in .local }, requestDownload: { _ in }, readFile: { url in
            if url.lastPathComponent == "a.summary.json" { started.fulfill(); await gate.wait() }
            return try Data(contentsOf: url)
        })
        let store = SummaryStore(baseDirectory: dir, fileAccess: access)
        let a = Task { try await store.loadSummary(for: "a.mp3") }
        await fulfillment(of: [started], timeout: 2)
        let b = Task { let value = try await store.loadSummary(for: "b.mp3"); bReady.fulfill(); return value }
        await fulfillment(of: [bReady], timeout: 2)
        // Always release A after the bounded independence assertion, even on failure.
        await gate.release()
        let loadedB = try await b.value
        XCTAssertEqual(loadedB?.recordingFilename, "b.mp3")
        await gate.release(); _ = try await a.value
    }

    func testLateSummaryReadCannotOverwriteNewlySavedSummary() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let writer = SummaryStore(baseDirectory: dir)
        try await writer.save(summary("a.mp3", text: "Old"), mp3Filename: "a.mp3")
        let bytes = try Data(contentsOf: dir.appendingPathComponent("a.summary.json"))
        let gate = Gate(), started = expectation(description: "Old read pending")
        let access = RecordingFileAccess(availability: { _ in .local }, requestDownload: { _ in }, readFile: { _ in
            started.fulfill(); await gate.wait(); return bytes
        })
        let store = SummaryStore(baseDirectory: dir, fileAccess: access)
        let pending = Task { try await store.loadSummary(for: "a.mp3") }
        await fulfillment(of: [started], timeout: 2)
        try await store.save(summary("a.mp3", text: "New"), mp3Filename: "a.mp3")
        await gate.release()
        let result = try await pending.value
        XCTAssertEqual(result?.sections.first?.content, "New")
    }

    func testLateTranscriptReadCannotResurrectDeletedTranscript() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let writer = TranscriptStore(baseDirectory: dir)
        try await writer.save(transcript("a.mp3"), mp3Filename: "a.mp3")
        let bytes = try Data(contentsOf: dir.appendingPathComponent("a.transcript.json"))
        let gate = Gate(), started = expectation(description: "Old read pending")
        let access = RecordingFileAccess(availability: { _ in .local }, requestDownload: { _ in }, readFile: { _ in
            started.fulfill(); await gate.wait(); return bytes
        })
        let store = TranscriptStore(baseDirectory: dir, fileAccess: access)
        let pending = Task { try await store.loadTranscript(for: "a.mp3") }
        await fulfillment(of: [started], timeout: 2)
        try await store.delete(for: "a.mp3")
        await gate.release()
        let result = try await pending.value
        XCTAssertNil(result)
        let exists = await store.hasTranscript(for: "a.mp3")
        XCTAssertFalse(exists)
    }
}
