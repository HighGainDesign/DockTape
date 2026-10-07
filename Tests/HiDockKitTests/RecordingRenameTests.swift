// © 2026 High Gain Design. All rights reserved.

import Foundation
import XCTest
@testable import HiDockKit

final class RecordingRenameTests: XCTestCase {
    func testTranscriptRenameUpdatesUncachedMovedJSON() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = Transcript(recordingFilename: "old.mp3", transcriptionModel: "test",
                                  hasSpeakerLabels: false,
                                  segments: [.init(startTime: 0, endTime: 1, text: "Keep this text")])
        let writer = TranscriptStore(baseDirectory: directory)
        try await writer.save(original, mp3Filename: "old.mp3")
        let store = TranscriptStore(baseDirectory: directory)
        try await store.loadAll()
        try FileManager.default.moveItem(at: directory.appendingPathComponent("old.transcript.json"),
                                        to: directory.appendingPathComponent("new.transcript.json"))
        try await store.rename(from: "old.mp3", to: "new.mp3")
        let reloaded = TranscriptStore(baseDirectory: directory)
        try await reloaded.loadAll()
        let result = await reloaded.transcript(for: "new.mp3")
        let oldExists = await store.hasTranscript(for: "old.mp3")
        XCTAssertEqual(result?.recordingFilename, "new.mp3")
        XCTAssertEqual(result?.segments.first?.text, "Keep this text")
        XCTAssertFalse(oldExists)
    }

    func testSummaryRenameUpdatesUncachedMovedJSON() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = Summary(recordingFilename: "old.mp3", model: "test", provider: "test",
                               templateUsed: "memo", sections: [.init(heading: "Summary", content: "Keep this summary")])
        let writer = SummaryStore(baseDirectory: directory)
        try await writer.save(original, mp3Filename: "old.mp3")
        let store = SummaryStore(baseDirectory: directory)
        try await store.loadAll()
        try FileManager.default.moveItem(at: directory.appendingPathComponent("old.summary.json"),
                                        to: directory.appendingPathComponent("new.summary.json"))
        try await store.rename(from: "old.mp3", to: "new.mp3")
        let reloaded = SummaryStore(baseDirectory: directory)
        try await reloaded.loadAll()
        let result = await reloaded.summary(for: "new.mp3")
        let oldExists = await store.hasSummary(for: "old.mp3")
        XCTAssertEqual(result?.recordingFilename, "new.mp3")
        XCTAssertEqual(result?.sections.first?.content, "Keep this summary")
        XCTAssertFalse(oldExists)
    }

    func testRenameMovesPendingPlainTextFlushToNewFilename() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcript = Transcript(recordingFilename: "old.mp3", transcriptionModel: "test",
                                    hasSpeakerLabels: true,
                                    segments: [.init(startTime: 0, endTime: 1, text: "Keep text", speakerID: "Speaker 1")])
        let store = TranscriptStore(baseDirectory: directory)
        try await store.save(transcript, mp3Filename: "old.mp3")
        try await store.updateSpeakerNames(for: "old.mp3", names: ["Speaker 1": "Alex"])
        try FileManager.default.moveItem(at: directory.appendingPathComponent("old.transcript.json"),
                                        to: directory.appendingPathComponent("new.transcript.json"))
        try await store.rename(from: "old.mp3", to: "new.mp3")
        await store.flushPendingTxtWrites()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("old.txt").path))
        let text = try String(contentsOf: directory.appendingPathComponent("new.txt"), encoding: .utf8)
        XCTAssertTrue(text.contains("Alex"))
    }
    func testRenamePreservesInferredDateModeAndFolderAfterReload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecordingStore(baseDirectory: directory)
        try await store.setup()
        try await store.createFolder(named: "Meetings")
        let oldFilename = "Meetings/2026Oct06-090100-Mee00.mp3"
        try Data([0xff, 0xfb]).write(to: directory.appendingPathComponent(oldFilename))
        let beforeRecordings = await store.allRecordings()
        let before = try XCTUnwrap(beforeRecordings.first)
        let newFilename = try await store.renameRecording(filename: oldFilename, to: "Client call")
        XCTAssertEqual(newFilename, "Meetings/Client call.mp3")
        let reloaded = RecordingStore(baseDirectory: directory)
        try await reloaded.setup()
        let afterRecordings = await reloaded.allRecordings()
        let after = try XCTUnwrap(afterRecordings.first)
        XCTAssertEqual(after.recordedAt, before.recordedAt)
        XCTAssertEqual(after.mode, before.mode)
        XCTAssertEqual(after.folder, "Meetings")
        let stillImported = await reloaded.isDownloaded(filename: "2026Oct06-090100-Mee00.hda")
        XCTAssertTrue(stillImported, "Legacy filename identity should survive rename and reload")
    }

    func testFolderMovePreservesTranscriptAndSummaryAfterReload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecordingStore(baseDirectory: directory)
        try await store.setup()
        try await store.createFolder(named: "Meetings")
        try Data([0xff, 0xfb]).write(to: directory.appendingPathComponent("call.mp3"))
        let transcripts = TranscriptStore(baseDirectory: directory)
        let summaries = SummaryStore(baseDirectory: directory)
        try await transcripts.save(Transcript(recordingFilename: "call.mp3", transcriptionModel: "test",
                                              hasSpeakerLabels: false,
                                              segments: [.init(startTime: 0, endTime: 1, text: "Keep text")]),
                                   mp3Filename: "call.mp3")
        try await summaries.save(Summary(recordingFilename: "call.mp3", model: "test", provider: "test",
                                         templateUsed: "memo", sections: [.init(heading: "Summary", content: "Keep summary")]),
                                 mp3Filename: "call.mp3")
        let newFilename = try await store.moveRecording(filename: "call.mp3", toFolder: "Meetings")
        try await transcripts.rename(from: "call.mp3", to: newFilename)
        try await summaries.rename(from: "call.mp3", to: newFilename)
        let reloadedTranscript = await TranscriptStore(baseDirectory: directory).transcript(for: newFilename)
        let reloadedSummary = await SummaryStore(baseDirectory: directory).summary(for: newFilename)
        XCTAssertEqual(reloadedTranscript?.recordingFilename, newFilename)
        XCTAssertEqual(reloadedTranscript?.segments.first?.text, "Keep text")
        XCTAssertEqual(reloadedSummary?.recordingFilename, newFilename)
        XCTAssertEqual(reloadedSummary?.sections.first?.content, "Keep summary")
    }

    func testOrphanDestinationSidecarCannotReplaceRenamedTranscript() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecordingStore(baseDirectory: directory)
        try await store.setup()
        let audio = Data([0xff, 0xfb, 1, 2])
        try audio.write(to: directory.appendingPathComponent("old.mp3"))
        let orphan = Data("unrelated transcript".utf8)
        try orphan.write(to: directory.appendingPathComponent("new.transcript.json"))
        do {
            _ = try await store.renameRecording(filename: "old.mp3", to: "new")
            XCTFail("Rename should reject the orphan sidecar")
        } catch HiDockError.invalidFilename { }
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("old.mp3")), audio)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("new.transcript.json")), orphan)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("new.mp3").path))
    }

    func testStaleMetadataDoesNotSuppressRestoringMissingAudio() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecordingStore(baseDirectory: directory)
        try await store.setup()
        await store.setMeta(mode: "Rec", deviceFilename: "original.hda", for: "renamed.mp3")
        let imported = await store.isDownloaded(filename: "original.hda")
        XCTAssertFalse(imported)
        let importedNames = await store.allImportedDeviceFilenames()
        XCTAssertFalse(importedNames.contains("original.hda"))
    }

}
