// © 2026 High Gain Design. All rights reserved.

import XCTest
@testable import HiDockKit

final class RecordingStoreTests: XCTestCase {

    var tmpDir: URL!
    var store: RecordingStore!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = RecordingStore(baseDirectory: tmpDir)
        try await store.setup()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func testSetupCreatesDirectory() async throws {
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmpDir.path))
    }

    func testStoreAndRetrieveRecording() async throws {
        // Create fake .hda data with MP3 sync
        var hda = Data([0x00, 0x01])
        hda.append(contentsOf: [0xFF, 0xFB] as [UInt8])
        hda.append(Data(repeating: 0xAA, count: 100))

        let entry = FileEntry(filename: "REC_20240315_143000.hda", size: UInt32(hda.count))
        let meta = try await store.storeRecording(hdaData: hda, entry: entry)

        XCTAssertEqual(meta.filename, "REC_20240315_143000.mp3")
        XCTAssertEqual(meta.mode, "Rec")
        XCTAssertNotNil(meta.recordedAt)

        // Verify MP3 file exists
        let mp3URL = await store.mp3URL(for: meta)
        XCTAssertTrue(FileManager.default.fileExists(atPath: mp3URL.path))

        // Verify the MP3 data is correct (stripped header)
        let mp3Data = try Data(contentsOf: mp3URL)
        XCTAssertEqual(mp3Data[0], 0xFF)
        XCTAssertEqual(mp3Data[1], 0xFB)

        // Check allRecordings
        let all = await store.allRecordings()
        XCTAssertEqual(all.count, 1)
    }

    func testIsDownloaded() async throws {
        let isDown = await store.isDownloaded(filename: "REC_20240315_143000.hda")
        XCTAssertFalse(isDown)

        var hda = Data([0xFF, 0xFB])
        hda.append(Data(repeating: 0xAA, count: 50))
        let entry = FileEntry(filename: "REC_20240315_143000.hda", size: UInt32(hda.count))
        try await store.storeRecording(hdaData: hda, entry: entry)

        let isDownNow = await store.isDownloaded(filename: "REC_20240315_143000.hda")
        XCTAssertTrue(isDownNow)

        // Also works with MP3 filename
        let isDownMp3 = await store.isDownloaded(filename: "REC_20240315_143000.mp3")
        XCTAssertTrue(isDownMp3)
    }

    func testDeleteRecording() async throws {
        var hda = Data([0xFF, 0xFB])
        hda.append(Data(repeating: 0xAA, count: 50))
        let entry = FileEntry(filename: "REC_20240315_143000.hda", size: UInt32(hda.count))
        let meta = try await store.storeRecording(hdaData: hda, entry: entry)

        let mp3URL = await store.mp3URL(for: meta)
        XCTAssertTrue(FileManager.default.fileExists(atPath: mp3URL.path))

        try await store.deleteRecording(filename: "REC_20240315_143000.mp3")

        let all = await store.allRecordings()
        XCTAssertEqual(all.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: mp3URL.path))
    }

    func testMetadataPersistence() async throws {
        var hda = Data([0xFF, 0xFB])
        hda.append(Data(repeating: 0xAA, count: 50))
        let entry = FileEntry(filename: "REC_20240315_143000.hda", size: UInt32(hda.count))
        try await store.storeRecording(hdaData: hda, entry: entry)

        // Create a new store pointing at the same directory — should find the MP3
        let store2 = RecordingStore(baseDirectory: tmpDir)
        try await store2.setup()
        let all = await store2.allRecordings()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].filename, "REC_20240315_143000.mp3")
    }

    func testDuplicateStoreReplaces() async throws {
        var hda = Data([0xFF, 0xFB])
        hda.append(Data(repeating: 0xAA, count: 50))
        let entry = FileEntry(filename: "REC_20240315_143000.hda", size: UInt32(hda.count))

        try await store.storeRecording(hdaData: hda, entry: entry)
        try await store.storeRecording(hdaData: hda, entry: entry) // store again

        let all = await store.allRecordings()
        XCTAssertEqual(all.count, 1) // should not duplicate
    }

    func testRenameRecording() async throws {
        var hda = Data([0xFF, 0xFB])
        hda.append(Data(repeating: 0xAA, count: 50))
        let entry = FileEntry(filename: "REC_20240315_143000.hda", size: UInt32(hda.count))
        try await store.storeRecording(hdaData: hda, entry: entry)

        let newFilename = try await store.renameRecording(
            filename: "REC_20240315_143000.mp3", to: "Team standup")
        XCTAssertEqual(newFilename, "Team standup.mp3")

        let all = await store.allRecordings()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].filename, "Team standup.mp3")

        // Old file should be gone
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: tmpDir.appendingPathComponent("REC_20240315_143000.mp3").path))
        // New file should exist
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tmpDir.appendingPathComponent("Team standup.mp3").path))
    }
}
