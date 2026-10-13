// © 2026 High Gain Design. All rights reserved.

import AppKit
import HiDockKit

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

        let bytes = Data([0xFF, 0xFB, 0xAA, 0xAA])
        let entry = FileEntry(filename: "recording.hda", size: 4, md5: "bb8e5c306ef0dfbe6fa05803f2ed69ab")
        await transport.enqueue(sequence: 1, bytes: bytes)
        await state.downloadFile(entry)
        try expect(state.errorMessage == nil && state.library.recordings.count == 1, "A new import must enter the library")
        let audioURL = directory.appendingPathComponent("recording.mp3")
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
        try Data([0xBB]).write(to: directory.appendingPathComponent(moved))
        await transport.enqueue(sequence: 2, bytes: bytes)
        await state.downloadFile(entry)
        try expect(state.errorMessage == nil && state.statusMessage.hasPrefix("Re-imported"), "Changed audio must show a repair result")
        try expect(state.statusMessage.contains("Review"), "Repair must surface sidecar review")
        try expect(state.library.recordings.map(\.filename) == ["Archive/meeting.mp3"], "Repair must keep the renamed/moved library entry")
        try expect(try Data(contentsOf: directory.appendingPathComponent(moved)) == bytes, "Repair must restore device audio")
        try expect(!state.device.isDeviceBusy, "Import completion must clear the busy state")

        let menu = MainMenu.build(appState: state)
        let deviceMenu = menu.items.compactMap(\.submenu).first { $0.title == "Device" }
        try expect(deviceMenu?.items.contains { $0.title == "Import All" } == true, "Batch import must have its visible menu label")
        print("Actual AppState import checks passed: new, identical skip, corruption repair, location, status, busy state and menu label.")
    }

    private static func expect(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(description: message) }
    }
}
