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

    func testLegacyMovesPreservePathMetadataAcrossRenameAndRestart() async throws {
        let original = Data("Synthetic original".utf8)
        try original.write(to: tmpDir.appendingPathComponent("Clip.mp3"))
        try await store.setMeta(mode: "Wip", deviceFilename: "synthetic-device.hda", for: "Clip.mp3")
        try await store.createFolder(named: "Folder")
        let moved = try await store.moveRecording(filename: "Clip.mp3", toFolder: "Folder")
        let renamed = try await store.renameRecording(filename: moved, to: "Renamed")
        let out = try await store.moveRecording(filename: renamed, toFolder: nil)
        let mode = await store.mode(for: out)
        XCTAssertEqual(mode, "Wip")
        let restarted = RecordingStore(baseDirectory: tmpDir); try await restarted.setup()
        let persisted = await restarted.mode(for: out), imported = await restarted.isImported(deviceFilename: "synthetic-device.hda")
        XCTAssertEqual(persisted, "Wip"); XCTAssertTrue(imported)
        XCTAssertEqual(try Data(contentsOf: tmpDir.appendingPathComponent(out)), original)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: tmpDir.appendingPathComponent("library.json"))) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["Renamed.mp3"], "Moving metadata must not leave orphan aliases")
    }

    func testLegacyFolderRenamePreservesNestedMetadataAndUnrelatedSameBasename() async throws {
        for folder in ["Before/Nested", "Other"] {
            try FileManager.default.createDirectory(at: tmpDir.appendingPathComponent(folder), withIntermediateDirectories: true)
            try Data(("Synthetic " + folder).utf8).write(to: tmpDir.appendingPathComponent(folder + "/Clip.mp3"))
        }
        try await store.setMeta(mode: "Pho", deviceFilename: "nested-device.hda", for: "Before/Nested/Clip.mp3")
        try await store.setMeta(mode: "Rec", deviceFilename: "other-device.hda", for: "Other/Clip.mp3")
        let libraryURL = tmpDir.appendingPathComponent("library.json")
        var before = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: libraryURL)) as? [String: [String: Any]])
        before["Before/Nested/Clip.mp3"]?["futureField"] = ["preserve": true]
        before["Before/Nested/Clip.mp3"]?["recordedAt"] = 12345.0
        try JSONSerialization.data(withJSONObject: before).write(to: libraryURL)
        _ = try await store.renameFolder(from: "Before", to: "After")
        let restarted = RecordingStore(baseDirectory: tmpDir); try await restarted.setup()
        let nested = await restarted.mode(for: "After/Nested/Clip.mp3"), other = await restarted.mode(for: "Other/Clip.mp3")
        XCTAssertEqual(nested, "Pho"); XCTAssertEqual(other, "Rec")
        let imported = await restarted.allImportedDeviceFilenames()
        XCTAssertEqual(imported, ["nested-device.hda", "other-device.hda"])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: tmpDir.appendingPathComponent("library.json"))) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["After/Nested/Clip.mp3", "Other/Clip.mp3"])
        let nestedObject = try XCTUnwrap(object["After/Nested/Clip.mp3"] as? [String: Any])
        XCTAssertEqual(nestedObject["futureField"] as? [String: Bool], ["preserve": true])
        let entries = await restarted.allRecordings()
        XCTAssertEqual(entries.first { $0.filename == "After/Nested/Clip.mp3" }?.recordedAt, Date(timeIntervalSinceReferenceDate: 12345))
    }

    func testCancellationAfterLegacyMoveFinishesMetadataRelocation() async throws {
        for folderRename in [false, true] {
            let root = tmpDir.appendingPathComponent(folderRename ? "folder" : "recording")
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Before"), withIntermediateDirectories: true)
            let audio = Data("Owned cancellation fixture".utf8)
            try audio.write(to: root.appendingPathComponent("Before/Clip.mp3"))
            let records = RecordingStore(baseDirectory: root); try await records.setup()
            try await records.setMeta(mode: "Pho", deviceFilename: "synthetic-device.hda", for: "Before/Clip.mp3")
            let held = expectation(description: "Metadata held after physical move"), release = DispatchSemaphore(value: 0)
            let holder = Task { try await CoordinatedFileAccess().withWrite(at: root.appendingPathComponent("library.json")) { _ in
                held.fulfill(); _ = release.wait(timeout: .now() + 8)
            } }
            await fulfillment(of: [held], timeout: 1)
            let moving = Task {
                if folderRename { _ = try await records.renameFolder(from: "Before", to: "After") }
                else { _ = try await records.moveRecording(filename: "Before/Clip.mp3", toFolder: nil) }
            }
            let destination = folderRename ? "After/Clip.mp3" : "Clip.mp3"
            for _ in 0..<200 {
                if FileManager.default.fileExists(atPath: root.appendingPathComponent(destination).path) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(destination).path))
            moving.cancel(); release.signal(); try await holder.value
            do { try await moving.value } catch is CancellationError { }
            let restarted = RecordingStore(baseDirectory: root); try await restarted.setup()
            let mode = await restarted.mode(for: destination), imported = await restarted.isImported(deviceFilename: "synthetic-device.hda")
            XCTAssertEqual(mode, "Pho", "A completed physical move must finish its metadata rekey despite cancellation")
            XCTAssertTrue(imported)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("library.json"))) as? [String: Any])
            XCTAssertEqual(Set(object.keys), [destination])
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(destination)), audio)
        }
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

    func testIdenticalImportDoesNotRewriteAudioOrSidecars() async throws {
        let name = "REC_20240315_143000"
        let original = Data([0xFF, 0xFB, 0xAA, 0xAA])
        let entry = FileEntry(filename: name + ".hda", size: UInt32(original.count))
        try await store.storeRecording(hdaData: original, entry: entry)
        let url = tmpDir.appendingPathComponent(name + ".mp3")
        let oldFileID = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber
        let transcript = Data("original transcript".utf8)
        let summary = Data("original summary".utf8)
        try transcript.write(to: tmpDir.appendingPathComponent(name + ".transcript.json"))
        try summary.write(to: tmpDir.appendingPathComponent(name + ".summary.json"))
        try await store.storeRecording(hdaData: original, entry: entry)
        let newFileID = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber
        XCTAssertEqual(newFileID, oldFileID, "Identical audio must not be atomically replaced")
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(try Data(contentsOf: tmpDir.appendingPathComponent(name + ".transcript.json")), transcript)
        XCTAssertEqual(try Data(contentsOf: tmpDir.appendingPathComponent(name + ".summary.json")), summary)
    }

    func testChangedImportRepairsRenamedMovedAudioWithoutExtraFiles() async throws {
        let original = Data([0xFF, 0xFB, 0xAA, 0xAA])
        let entry = FileEntry(filename: "REC_20240315_143000.hda", size: UInt32(original.count))
        let metadata = try await store.storeRecording(hdaData: original, entry: entry)
        let renamed = try await store.renameRecording(filename: metadata.filename, to: "meeting")
        try await store.createFolder(named: "Archive")
        let moved = try await store.moveRecording(filename: renamed, toFolder: "Archive")
        let transcriptURL = tmpDir.appendingPathComponent("Archive/meeting.transcript.json")
        let summaryURL = tmpDir.appendingPathComponent("Archive/meeting.summary.json")
        let transcript = Data("saved transcript".utf8)
        let summary = Data("saved summary".utf8)
        try transcript.write(to: transcriptURL)
        try summary.write(to: summaryURL)
        // Simulate corrupt local/cloud bytes without changing the device recording.
        try Data([0xFF, 0xFB, 0xBB]).write(to: tmpDir.appendingPathComponent(moved))
        let repaired = try await store.storeRecording(hdaData: original, entry: entry)
        XCTAssertEqual(repaired.filename, "Archive/meeting.mp3")
        XCTAssertEqual(repaired.recordedAt, metadata.recordedAt)
        XCTAssertEqual(try Data(contentsOf: tmpDir.appendingPathComponent(moved)), original)
        XCTAssertEqual(try Data(contentsOf: transcriptURL), transcript)
        XCTAssertEqual(try Data(contentsOf: summaryURL), summary)
        let all = await store.allRecordings()
        XCTAssertEqual(all.map(\.filename), ["Archive/meeting.mp3"])
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: tmpDir.appendingPathComponent("Archive").path)),
                       Set(["meeting.mp3", "meeting.transcript.json", "meeting.summary.json"]))
    }

    func testImportCannotReuseAnUnrelatedOrphanSidecarDestination() async throws {
        for suffix in [".transcript.json", ".summary.json", ".txt"] {
            let dir = tmpDir.appendingPathComponent(UUID().uuidString)
            let isolatedStore = RecordingStore(baseDirectory: dir)
            try await isolatedStore.setup()
            let reservedName = suffix == ".mp3.icloud" ? ".recording" + suffix : "recording" + suffix
            let reservedURL = dir.appendingPathComponent(reservedName)
            let original = Data("existing content".utf8)
            try original.write(to: reservedURL)
            do {
                try await isolatedStore.storeRecording(
                    hdaData: Data([0xFF, 0xFB, 0xAA]),
                    entry: FileEntry(filename: "recording.hda", size: 3))
                XCTFail("Import must reject reserved destination: \(suffix)")
            } catch {}
            XCTAssertEqual(try Data(contentsOf: reservedURL), original)
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("recording.mp3").path))
        }
    }

    func testBadTransferCannotReplaceVerifiedAudio() async throws {
        let original = Data([0xFF, 0xFB, 0xAA, 0xAA])
        let entry = FileEntry(filename: "recording.hda", size: 4, md5: "bb8e5c306ef0dfbe6fa05803f2ed69ab")
        try await store.storeRecording(hdaData: original, entry: entry)
        for bad in [Data([0xFF, 0xFB, 0xBB, 0xBB]), Data([0xFF, 0xFB, 0xAA])] {
            do {
                try await store.storeRecording(hdaData: bad, entry: entry)
                XCTFail("A mismatched checksum or incomplete transfer must not replace good audio")
            } catch {}
            XCTAssertEqual(try Data(contentsOf: tmpDir.appendingPathComponent("recording.mp3")), original)
        }
    }

    func testChangedSourceWithUnprovenChecksumCoverageStillReimports() async throws {
        try await store.storeRecording(hdaData: Data([0xFF, 0xFB, 0xAA, 0xAA]),
            entry: FileEntry(filename: "recording.hda", size: 4, md5: "bb8e5c306ef0dfbe6fa05803f2ed69ab"))
        // A later source reports an MP3 fingerprint rather than raw HDA coverage.
        // Its changed fingerprint is not proof of the old coverage contract.
        let hda = Data([0x00, 0xFF, 0xFB, 0xBB, 0xBB])
        let entry = FileEntry(filename: "recording.hda", size: 5, md5: "2b88e3e302ad447d456ddc88394bd046")
        let updated = try await store.importRecording(hdaData: hda, entry: entry)
        XCTAssertEqual(updated?.filename, "recording.mp3")
        XCTAssertEqual(try Data(contentsOf: tmpDir.appendingPathComponent("recording.mp3")), Data([0xFF, 0xFB, 0xBB, 0xBB]))
        let verified = try await store.matchesVerifiedImport(entry)
        XCTAssertFalse(verified, "Unproven raw checksum coverage must use a new transfer next time")
    }

    func testHeaderCoverageChangeCanRestoreTheTrustedAudioBaseline() async throws {
        let audio = Data([0xFF, 0xFB, 0xAA, 0xAA])
        try await store.storeRecording(hdaData: audio,
            entry: FileEntry(filename: "recording.hda", size: 4, md5: "bb8e5c306ef0dfbe6fa05803f2ed69ab"))
        try Data([0xBB]).write(to: tmpDir.appendingPathComponent("recording.mp3"))
        let entry = FileEntry(filename: "recording.hda", size: 5, md5: "bb8e5c306ef0dfbe6fa05803f2ed69ab")
        let result = try await store.importRecording(hdaData: Data([0x00]) + audio, entry: entry)
        XCTAssertNotNil(result)
        XCTAssertEqual(try Data(contentsOf: tmpDir.appendingPathComponent("recording.mp3")), audio)
    }

    func testLegacyImportGetsVerifiedWithoutRewritingItsAudio() async throws {
        let bytes = Data([0xFF, 0xFB, 0xAA, 0xAA])
        let url = tmpDir.appendingPathComponent("recording.mp3")
        try bytes.write(to: url)
        // No library.json/source hash existed for this legacy recording.
        let fileID = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber
        let entry = FileEntry(filename: "recording.hda", size: 4, md5: "bb8e5c306ef0dfbe6fa05803f2ed69ab")
        let before = try await store.matchesVerifiedImport(entry)
        XCTAssertFalse(before, "An unverified legacy file is not enough to skip")
        let imported = try await store.importRecording(hdaData: bytes, entry: entry)
        XCTAssertNil(imported)
        let verified = try await store.matchesVerifiedImport(entry)
        XCTAssertTrue(verified)
        let afterID = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber
        XCTAssertEqual(afterID, fileID)
        // Check persisted evidence, not just an in-memory hash.
        let reloaded = RecordingStore(baseDirectory: tmpDir)
        try await reloaded.setup()
        let persisted = try await reloaded.matchesVerifiedImport(entry)
        XCTAssertTrue(persisted)
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
