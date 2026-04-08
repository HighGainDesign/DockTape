import XCTest
@testable import HiDockKit

/// Mock DeviceManager for SyncEngine testing.
actor MockDeviceManager {
    var files: [FileEntry] = []
    var downloadedFiles: [String: Data] = [:]
    var deletedFiles: [String] = []

    func setFiles(_ entries: [FileEntry]) {
        files = entries
    }

    func setDownloadData(_ filename: String, data: Data) {
        downloadedFiles[filename] = data
    }
}

final class SyncEngineTests: XCTestCase {

    func testTranscriptStoreRoundTrip() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = TranscriptStore(baseDirectory: tmpDir)

        let transcript = Transcript(
            recordingFilename: "2026Mar30-172146-Rec00.hda",
            transcriptionModel: "parakeet-tdt-1.0",
            hasSpeakerLabels: true,
            segments: [
                .init(startTime: 0, endTime: 10, text: "Hello world", speakerID: "S1"),
                .init(startTime: 10, endTime: 20, text: "Hi there", speakerID: "S2"),
            ],
            speakerNames: ["S1": "Alice", "S2": "Bob"]
        )

        let mp3Name = "2026Mar30-172146-Rec00.mp3"
        try await store.save(transcript, mp3Filename: mp3Name)
        let hasSaved = await store.hasTranscript(for: mp3Name)
        XCTAssertTrue(hasSaved)

        let loaded = await store.transcript(for: mp3Name)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded!.segments.count, 2)
        XCTAssertEqual(loaded!.speakerNames["S1"], "Alice")

        // Test loadAll from fresh store
        let store2 = TranscriptStore(baseDirectory: tmpDir)
        try await store2.loadAll()
        let reloaded = await store2.transcript(for: mp3Name)
        XCTAssertNotNil(reloaded)
        XCTAssertEqual(reloaded!.segments.count, 2)
    }

    func testTranscriptStoreSpeakerRename() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = TranscriptStore(baseDirectory: tmpDir)
        let mp3Name = "test.mp3"

        let transcript = Transcript(
            recordingFilename: "test.hda",
            transcriptionModel: "test",
            hasSpeakerLabels: true,
            segments: [.init(startTime: 0, endTime: 5, text: "Test", speakerID: "S1")],
            speakerNames: ["S1": "Speaker 1"]
        )

        try await store.save(transcript, mp3Filename: mp3Name)
        try await store.updateSpeakerNames(for: mp3Name, names: ["S1": "CEO"])

        let updated = await store.transcript(for: mp3Name)
        XCTAssertEqual(updated!.speakerNames["S1"], "CEO")
    }

    func testTranscriptStoreDelete() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = TranscriptStore(baseDirectory: tmpDir)
        let mp3Name = "test.mp3"

        let transcript = Transcript(
            recordingFilename: "test.hda",
            transcriptionModel: "test",
            hasSpeakerLabels: false,
            segments: [.init(startTime: 0, endTime: 5, text: "Test")]
        )

        try await store.save(transcript, mp3Filename: mp3Name)
        let hasIt = await store.hasTranscript(for: mp3Name)
        XCTAssertTrue(hasIt)

        try await store.delete(for: mp3Name)
        let gone = await store.hasTranscript(for: mp3Name)
        XCTAssertFalse(gone)
    }
}
