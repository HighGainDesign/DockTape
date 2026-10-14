// © 2026 High Gain Design. All rights reserved.

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

    func testIndividualImportSkipsExistingAudioEvenAfterRenameAndMove() async throws {
        for relocate in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = RecordingStore(baseDirectory: directory)
            try await store.setup()
            let original = Data([0xFF, 0xFB, 0xAA, 0xAA])
            let entry = FileEntry(filename: "recording.hda", size: UInt32(original.count), md5: "bb8e5c306ef0dfbe6fa05803f2ed69ab")
            let metadata = try await store.storeRecording(hdaData: original, entry: entry)
            var filename = metadata.filename
            if relocate {
                filename = try await store.renameRecording(filename: filename, to: "meeting")
                try await store.renameMeta(from: metadata.filename, to: filename)
                try await store.createFolder(named: "Archive")
                filename = try await store.moveRecording(filename: filename, toFolder: "Archive")
            }
            let model = await DeviceModel(id: "test")
            let manager = DeviceManager(device: model)
            let transport = MockDeviceTransport()
            await manager.connect(via: transport)
            let engine = SyncEngine(deviceManager: manager, store: store)
            let result = try await engine.downloadFile(entry, deleteAfterDownload: true)
            XCTAssertNil(result, "Existing imports must report a skip")
            XCTAssertTrue(transport.sentData.isEmpty, "Skipping must not transfer or delete device data")
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(filename)), original)
            let all = await store.allRecordings()
            XCTAssertEqual(all.count, 1)
        }
    }

    func testIndividualImportRepairsCorruptAudioAndPreservesRenamedLocation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecordingStore(baseDirectory: directory)
        try await store.setup()
        let bytes = Data([0xFF, 0xFB, 0xAA, 0xAA])
        let entry = FileEntry(filename: "recording.hda", size: 4, md5: "bb8e5c306ef0dfbe6fa05803f2ed69ab")
        try await store.storeRecording(hdaData: bytes, entry: entry)
        let renamed = try await store.renameRecording(filename: "recording.mp3", to: "meeting")
        try Data([0xFF, 0xFB, 0xBB]).write(to: directory.appendingPathComponent(renamed))
        let model = await DeviceModel(id: "test")
        let manager = DeviceManager(device: model)
        let transport = MockDeviceTransport()
        transport.queueFrameResponse(command: .transferFile, sequence: 1, body: bytes)
        await manager.connect(via: transport)
        let engine = SyncEngine(deviceManager: manager, store: store)
        let result = try await engine.downloadFile(entry)
        XCTAssertNotNil(result)
        XCTAssertEqual(transport.sentData.count, 1)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(renamed)), bytes)
        let all = await store.allRecordings()
        XCTAssertEqual(all.map(\.filename), ["meeting.mp3"])
    }

    func testUnverifiedDeviceChecksumUsesTransferAndSkipsIdenticalAudio() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecordingStore(baseDirectory: directory)
        try await store.setup()
        let bytes = Data([0xFF, 0xFB, 0xAA, 0xAA])
        let entry = FileEntry(filename: "recording.hda", size: 4, md5: "not-a-verified-checksum")
        try await store.storeRecording(hdaData: bytes, entry: entry)
        let audioURL = directory.appendingPathComponent("recording.mp3")
        let oldFileID = try FileManager.default.attributesOfItem(atPath: audioURL.path)[.systemFileNumber] as? NSNumber
        let model = await DeviceModel(id: "test")
        let manager = DeviceManager(device: model)
        let transport = MockDeviceTransport()
        transport.queueFrameResponse(command: .transferFile, sequence: 1, body: bytes)
        await manager.connect(via: transport)
        let engine = SyncEngine(deviceManager: manager, store: store)
        let result = try await engine.downloadFile(entry, deleteAfterDownload: true)
        XCTAssertNil(result)
        XCTAssertEqual(transport.sentData.count, 1, "Fallback comparison transfers once, without a delete")
        let newFileID = try FileManager.default.attributesOfItem(atPath: audioURL.path)[.systemFileNumber] as? NSNumber
        XCTAssertEqual(newFileID, oldFileID)
    }

    func testIndividualImportTransfersANewRecording() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecordingStore(baseDirectory: directory)
        try await store.setup()
        let model = await DeviceModel(id: "test")
        let manager = DeviceManager(device: model)
        let bytes = Data([0x00, 0xFF, 0xFB, 0xAA])
        let transport = MockDeviceTransport()
        transport.queueFrameResponse(command: .transferFile, sequence: 1, body: bytes)
        await manager.connect(via: transport)
        let engine = SyncEngine(deviceManager: manager, store: store)
        let result = try await engine.downloadFile(FileEntry(filename: "recording.hda", size: UInt32(bytes.count)))
        XCTAssertNotNil(result)
        XCTAssertNotNil(result?.recordedAt, "Unrecognized device filenames retain the file-date fallback")
        XCTAssertEqual(transport.sentData.count, 1)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("recording.mp3")), Data([0xFF, 0xFB, 0xAA]))
    }

    func testMissingDeviceChecksumAfterAValidatedImportFallsBackToComparison() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecordingStore(baseDirectory: directory)
        try await store.setup()
        let bytes = Data([0xFF, 0xFB, 0xAA, 0xAA])
        try await store.storeRecording(hdaData: bytes,
            entry: FileEntry(filename: "recording.hda", size: 4, md5: "bb8e5c306ef0dfbe6fa05803f2ed69ab"))
        let model = await DeviceModel(id: "test")
        let manager = DeviceManager(device: model)
        let transport = MockDeviceTransport()
        transport.queueFrameResponse(command: .transferFile, sequence: 1, body: bytes)
        await manager.connect(via: transport)
        let engine = SyncEngine(deviceManager: manager, store: store)
        let result = try await engine.downloadFile(FileEntry(filename: "recording.hda", size: 4, md5: String(repeating: "0", count: 32)))
        XCTAssertNil(result)
        XCTAssertEqual(transport.sentData.count, 1)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("recording.mp3")), bytes)
    }

    func testSyncAllRepairsCorruptionThenSkipsVerifiedAudio() async throws {
        for corrupt in [true, false] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = RecordingStore(baseDirectory: directory)
            try await store.setup()
            let bytes = Data([0xFF, 0xFB, 0xAA, 0xAA])
            let entry = FileEntry(filename: "recording.hda", size: 4, md5: "bb8e5c306ef0dfbe6fa05803f2ed69ab")
            try await store.storeRecording(hdaData: bytes, entry: entry)
            if corrupt { try Data([0xBB]).write(to: directory.appendingPathComponent("recording.mp3")) }
            let model = await DeviceModel(id: "test")
            let manager = DeviceManager(device: model)
            let transport = MockDeviceTransport()
            transport.queueFrameResponse(command: .fileCount, sequence: 1, body: Data([0, 0, 0, 1]))
            var fileList = Data([0, 0, 0, 13])
            fileList.append(Data("recording.hda".utf8))
            fileList.append(Data([0, 0, 0, 4]))
            fileList.append(Data(repeating: 0, count: 6))
            fileList.append(Data([0xbb, 0x8e, 0x5c, 0x30, 0x6e, 0xf0, 0xdf, 0xbe,
                                  0x6f, 0xa0, 0x58, 0x03, 0xf2, 0xed, 0x69, 0xab]))
            transport.queueFrameResponse(command: .fileList, sequence: 2, body: fileList)
            if corrupt { transport.queueFrameResponse(command: .transferFile, sequence: 3, body: bytes) }
            await manager.connect(via: transport)
            let engine = SyncEngine(deviceManager: manager, store: store)
            let result = try await engine.syncAll()
            XCTAssertTrue(result.failed.isEmpty)
            XCTAssertEqual(result.downloaded.count, corrupt ? 1 : 0)
            XCTAssertEqual(result.skipped, corrupt ? [] : ["recording.hda"])
            XCTAssertEqual(transport.sentData.count, corrupt ? 3 : 2)
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("recording.mp3")), bytes)
        }
    }

    func testSyncAllContinuesAfterAnExistingFileCannotBeVerified() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let access = RecordingFileAccess(availability: { _ in .local }, requestDownload: { _ in },
            readFile: { url in
                if url.lastPathComponent == "a.mp3" { throw CocoaError(.fileReadNoPermission) }
                return try Data(contentsOf: url)
            })
        let store = RecordingStore(baseDirectory: directory, fileAccess: access)
        try await store.setup()
        let bytes = Data([0xFF, 0xFB, 0xAA, 0xAA])
        try await store.storeRecording(hdaData: bytes,
            entry: FileEntry(filename: "a.hda", size: 4, md5: "bb8e5c306ef0dfbe6fa05803f2ed69ab"))
        let model = await DeviceModel(id: "test")
        let manager = DeviceManager(device: model)
        let transport = MockDeviceTransport()
        transport.queueFrameResponse(command: .fileCount, sequence: 1, body: Data([0, 0, 0, 2]))
        var body = Data()
        for name in ["a.hda", "b.hda"] {
            body.append(Data([0, 0, 0, 5]) + Data(name.utf8) + Data([0, 0, 0, 4]))
            body.append(Data(repeating: 0, count: 6))
            body.append(name == "a.hda"
                ? Data([0xbb, 0x8e, 0x5c, 0x30, 0x6e, 0xf0, 0xdf, 0xbe, 0x6f, 0xa0, 0x58, 0x03, 0xf2, 0xed, 0x69, 0xab])
                : Data(repeating: 0, count: 16))
        }
        transport.queueFrameResponse(command: .fileList, sequence: 2, body: body)
        transport.queueFrameResponse(command: .transferFile, sequence: 3, body: bytes)
        await manager.connect(via: transport)
        let engine = SyncEngine(deviceManager: manager, store: store)
        let result = try await engine.syncAll()
        XCTAssertEqual(result.failed.map { $0.0 }, ["a.hda"])
        XCTAssertEqual(result.downloaded.map(\.filename), ["b.mp3"])
        XCTAssertEqual(transport.sentData.count, 3)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("a.mp3")), bytes)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("b.mp3")), bytes)
    }

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
