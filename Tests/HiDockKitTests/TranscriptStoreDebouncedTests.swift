// © 2026 High Gain Design. All rights reserved.

import XCTest
@testable import HiDockKit

final class TranscriptStoreDebouncedTests: XCTestCase {

    var tmpDir: URL!
    var store: TranscriptStore!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        store = TranscriptStore(baseDirectory: tmpDir)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func makeTranscript(filename: String = "test.mp3") -> Transcript {
        Transcript(
            recordingFilename: filename,
            transcriptionModel: "test",
            hasSpeakerLabels: true,
            segments: [
                .init(startTime: 0, endTime: 5, text: "Hello.", speakerID: "S1"),
                .init(startTime: 5, endTime: 10, text: "World.", speakerID: "S2"),
            ],
            speakerNames: ["S1": "Alice", "S2": "Bob"]
        )
    }

    func testSpeakerUpdateWritesJSONImmediately() async throws {
        let t = makeTranscript()
        try await store.save(t, mp3Filename: "test.mp3")

        try await store.updateSpeakerNames(for: "test.mp3", names: ["S1": "Carol", "S2": "Bob"])

        let loaded = await store.transcript(for: "test.mp3")
        XCTAssertEqual(loaded?.speakerNames["S1"], "Carol")
    }

    func testTxtRegeneratedAfterFlush() async throws {
        let t = makeTranscript()
        try await store.save(t, mp3Filename: "test.mp3")

        try await store.updateSpeakerNames(for: "test.mp3", names: ["S1": "Carol", "S2": "Bob"])

        await store.flushPendingTxtWrites()

        let txtURL = tmpDir.appendingPathComponent("test.txt")
        let txtContent = try String(contentsOf: txtURL, encoding: .utf8)
        XCTAssertTrue(txtContent.contains("Carol"))
    }

    func testStaleTxtDetectedOnLoad() async throws {
        let t = makeTranscript()
        try await store.save(t, mp3Filename: "test.mp3")
        await store.flushPendingTxtWrites()

        let txtURL = tmpDir.appendingPathComponent("test.txt")

        // Make TXT stale by setting its mod time to the past
        try "".write(to: txtURL, atomically: true, encoding: .utf8)
        let past = Date().addingTimeInterval(-10)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: txtURL.path)

        // Reload — should detect stale TXT
        let store2 = TranscriptStore(baseDirectory: tmpDir)
        try await store2.loadAll()
        await store2.flushPendingTxtWrites()

        let refreshed = try String(contentsOf: txtURL, encoding: .utf8)
        XCTAssertTrue(refreshed.contains("Alice"))
    }

    func testLoadAllFindsTranscriptsInSubfolders() async throws {
        // Create a transcript inside a subfolder, simulating a moved recording
        let subfolder = tmpDir.appendingPathComponent("Work")
        try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)

        let t = makeTranscript(filename: "Work/meeting.mp3")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(t)
        try data.write(to: subfolder.appendingPathComponent("meeting.transcript.json"))

        // loadAll should find it with the folder-relative key
        let store2 = TranscriptStore(baseDirectory: tmpDir)
        try await store2.loadAll()

        let loaded = await store2.transcript(for: "Work/meeting.mp3")
        XCTAssertNotNil(loaded, "loadAll() should find transcripts in subfolders")
        XCTAssertEqual(loaded?.segments.count, 2)
    }
}
