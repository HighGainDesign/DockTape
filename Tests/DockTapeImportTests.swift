// © 2026 High Gain Design. All rights reserved.

import AppKit
@testable import HiDockKit
import CryptoKit

/// Exercises the real app coordinator with a disposable library and mock USB.
@main
struct DockTapeImportTests {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    actor Transport: DeviceTransport {
        var responses: [Data] = []
        var sendCount = 0
        func enqueue(sequence: UInt32, bytes: Data) {
            responses.append(JensenFrame(command: .transferFile, sequence: sequence, body: bytes).encode())
        }
        func open() async throws {}
        func close() async {}
        func send(_ data: Data) async throws { sendCount += 1 }
        func receive(maxLength: Int) async throws -> Data {
            guard !responses.isEmpty else { throw TransportError.readTimeout }
            return responses.removeFirst()
        }
    }

    actor ReadGate {
        var waiting = false
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            waiting = true
            await withCheckedContinuation { continuation = $0 }
        }
        func release() { continuation?.resume(); continuation = nil }
    }

    @MainActor
    static func main() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DockTapeImportTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        // Volatile preferences prevent this executable from touching the user's
        // storage choices. AppState's hardware monitoring is never started.
        UserDefaults.standard.setVolatileDomain(["storageMode": "local"], forName: UserDefaults.argumentDomain)
        let state = AppState()
        let store = RecordingStore(baseDirectory: directory)
        state.library = LibraryState(store: store, transcriptStore: TranscriptStore(baseDirectory: directory))
        try await state.library.setup()
        let model = DeviceModel(id: "synthetic-import-test")
        let manager = DeviceManager(device: model)
        let transport = Transport()
        await manager.connect(via: transport)
        state.device.model = model
        state.device.deviceManager = manager
        state.device.syncEngine = SyncEngine(deviceManager: manager, store: store)

        let bytes = try Data(contentsOf: URL(fileURLWithPath: "Tests/HiDockKitTests/Fixtures/first.mp3"))
        let deviceFingerprint = Insecure.MD5.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let entry = FileEntry(filename: "recording.hda", size: UInt32(bytes.count), md5: deviceFingerprint)
        await transport.enqueue(sequence: 1, bytes: bytes)
        await state.downloadFile(entry)
        try expect(state.errorMessage == nil && state.library.recordings.count == 1, "A new import must enter the library")
        let audioURL = directory.appendingPathComponent("recording.mp3")
        let importedAudio = try Data(contentsOf: audioURL)
        let identifier = try FileManager.default.attributesOfItem(atPath: audioURL.path)[.systemFileNumber] as? NSNumber

        await state.downloadFile(entry)
        try expect(state.errorMessage == nil && state.statusMessage.hasPrefix("Already imported"), "Identical imports must show the skip result")
        let sendsAfterSkip = await transport.sendCount
        try expect(sendsAfterSkip == 1, "Verified skips must not send USB commands")
        let afterSkip = try FileManager.default.attributesOfItem(atPath: audioURL.path)[.systemFileNumber] as? NSNumber
        try expect(identifier == afterSkip, "Identical imports must not rewrite the MP3")

        let renamed = try await store.renameRecording(filename: "recording.mp3", to: "meeting")
        try await store.createFolder(named: "Archive")
        let moved = try await store.moveRecording(filename: renamed, toFolder: "Archive")
        await state.library.refresh()
        state.playback.play(file: moved, url: directory.appendingPathComponent(moved))
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while state.playback.avPlayer == nil && state.playback.loadError == nil {
            guard ContinuousClock.now < deadline else { throw Failure(description: "Playback preparation timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
        try expect(state.playback.avPlayer != nil, "Generated tone must prepare for playback")
        try Data([0xBB]).write(to: directory.appendingPathComponent(moved), options: .atomic)
        await transport.enqueue(sequence: 2, bytes: bytes)
        await state.downloadFile(entry)
        try expect(state.errorMessage == nil && state.statusMessage.hasPrefix("Re-imported"), "Changed audio must show a repair result")
        try expect(state.playback.avPlayer == nil && state.playback.playingFile == nil,
                   "Repair of the playing file must release the obsolete audio asset")
        try expect(state.statusMessage.contains("Review"), "Repair must surface sidecar review")
        try expect(state.library.recordings.map(\.filename) == ["Archive/meeting.mp3"], "Repair must keep the renamed/moved library entry")
        try expect(try Data(contentsOf: directory.appendingPathComponent(moved)) == importedAudio, "Repair must restore device audio")
        try expect(!state.device.isDeviceBusy, "Import completion must clear the busy state")

        let secondDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("DockTapeSecondLibrary-\(UUID())")
        defer {
            try? FileManager.default.removeItem(at: secondDirectory)
            UserDefaults.standard.removeObject(forKey: "libraryLocation")
            UserDefaults.standard.removeObject(forKey: "libraryLocationBookmark")
            UserDefaults.standard.removeObject(forKey: "storageMode")
        }
        state.device.isSyncing = true
        let refused = await state.switchStorageLocation(to: .custom, customURL: secondDirectory)
        try expect(!refused && state.library.store.baseDirectory == directory,
                   "Storage switching must be rejected while a device operation owns the current library")
        state.device.isSyncing = false
        state.errorMessage = nil
        let switched = await state.switchStorageLocation(to: .custom, customURL: secondDirectory)
        try expect(switched, "Idle storage switching must succeed")
        await transport.enqueue(sequence: 3, bytes: bytes)
        await state.downloadFile(entry)
        try expect(state.errorMessage == nil, "Import after storage switching must succeed")
        try expect(FileManager.default.fileExists(atPath: secondDirectory.appendingPathComponent("recording.mp3").path),
                   "Connected-device imports must target the chosen library")
        try expect(try Data(contentsOf: directory.appendingPathComponent(moved)) == importedAudio,
                   "Switching storage must leave previous-library recordings intact")

        // A late transcript from the previous library must not clear a new
        // library's timeline even when the recording filenames are identical.
        let gate = ReadGate()
        let oldTranscript = Transcript(recordingFilename: "recording.mp3", transcriptionModel: "test",
            hasSpeakerLabels: false, segments: [.init(startTime: 7, endTime: 8, text: "old library")])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let oldData = try encoder.encode(oldTranscript)
        let delayedAccess = RecordingFileAccess(availability: { _ in .local }, requestDownload: { _ in },
            readFile: { _ in await gate.wait(); return oldData })
        let oldLibrary = LibraryState(store: state.library.store,
            transcriptStore: TranscriptStore(baseDirectory: secondDirectory, fileAccess: delayedAccess))
        state.library = oldLibrary
        await oldLibrary.refresh()
        state.playRecording(oldLibrary.recordings[0])
        let oldRead = state.playbackTranscriptTask!
        let readDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await gate.waiting) {
            guard ContinuousClock.now < readDeadline else { throw Failure(description: "Transcript gate timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
        let thirdDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("DockTapeThirdLibrary-\(UUID())")
        defer { try? FileManager.default.removeItem(at: thirdDirectory); state.playback.stop() }
        try expect(await state.switchStorageLocation(to: .custom, customURL: thirdDirectory), "Second idle switch must succeed")
        await transport.enqueue(sequence: 4, bytes: bytes)
        await state.downloadFile(entry)
        let currentTranscript = Transcript(recordingFilename: "recording.mp3", transcriptionModel: "test",
            hasSpeakerLabels: false, segments: [.init(startTime: 0, endTime: 1, text: "current library")])
        try await state.library.transcriptStore.save(currentTranscript, mp3Filename: "recording.mp3")
        state.playRecording(state.library.recordings[0])
        await state.playbackTranscriptTask!.value
        await gate.release()
        await oldRead.value
        try expect(state.playback.segmentTimestamps.first?.start == 0,
                   "A cancelled previous-library read must not clear the new library's timeline")

        let menu = MainMenu.build(appState: state)
        let deviceMenu = menu.items.compactMap(\.submenu).first { $0.title == "Device" }
        try expect(deviceMenu?.items.contains { $0.title == "Import All" } == true, "Batch import must have its visible menu label")
        print("Actual AppState import checks passed: new, identical skip, corruption repair, location, status, playing-file invalidation, busy state, menu label, connected-device storage switching and late same-filename transcript isolation.")
    }

    private static func expect(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(description: message) }
    }
}
