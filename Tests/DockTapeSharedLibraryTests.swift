// © 2026 High Gain Design. All rights reserved.
import AppKit
import HiDockKit

@main
struct DockTapeSharedLibraryTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func expect(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    actor Provider: LLMProvider {
        nonisolated let name = "Synthetic"
        nonisolated let defaultModel = "fixture"
        nonisolated let availableModels = ["fixture"]
        func verifyKey() async throws {}
        var calls = 0
        func summarize(transcript: String, systemPrompt: String, model: String) async throws -> String {
            calls += 1
            return "Synthetic summary"
        }
    }
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        UserDefaults.standard.setVolatileDomain(["storageMode": "local"], forName: UserDefaults.argumentDomain)
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("DockTapeSharedApp-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("synthetic audio".utf8).write(to: root.appendingPathComponent("Meeting.mp3"))
        let legacy = RecordingStore(baseDirectory: root)
        try await legacy.setup()
        try await legacy.setMeta(mode: "Rec", deviceFilename: "device.hda", for: "Meeting.mp3")
        try await TranscriptStore(baseDirectory: root).save(Transcript(recordingFilename: "Meeting.mp3", transcriptionModel: "fixture",
            hasSpeakerLabels: true, segments: [.init(startTime: 0, endTime: 1, text: "Fixture", speakerID: "s")]), mp3Filename: "Meeting.mp3")
        try await SummaryStore(baseDirectory: root).save(Summary(recordingFilename: "Meeting.mp3", model: "fixture", provider: "fixture",
            templateUsed: "fixture", sections: [.init(heading: "Summary", content: "Fixture summary")]), mp3Filename: "Meeting.mp3")
        let identityFile = parent.appendingPathComponent("writer.json")
        let identity: @Sendable () async throws -> SharedLibraryWriterIdentity = {
            try await SharedLibraryWriterIdentityStore(file: identityFile, installationAnchor: "synthetic installation").load()
        }
        let witnesses = parent.appendingPathComponent("witnesses")
        let state = AppState(baseDirectory: root, sharedIdentity: identity, sharedWitnessDirectory: witnesses)
        try await state.setup()
        try expect(state.sharedLibrary.coordinator == nil, "Legacy startup must not enable metadata or acquire identity")
        try expect(!FileManager.default.fileExists(atPath: identityFile.path), "Legacy startup must not create a writer identity")
        try expect(await state.enableSharedLibrary(), "Explicit enable must connect the app to shared authority")
        try expect(state.sharedLibrary.coordinator != nil, "All shared stores must use one coordinator")
        let entity = try await state.sharedLibrary.coordinator!.recording(at: "Meeting.mp3").state.id
        _ = try await state.library.transcriptStore.loadTranscript(for: "Meeting.mp3")
        try await state.library.updateSpeakerNames(for: "Meeting.mp3", names: ["s": "Alice"])
        await state.refreshAll()
        let json = try Data(contentsOf: root.appendingPathComponent("Meeting.transcript.json"))
        try expect(String(decoding: json, as: UTF8.self).contains("Alice"), "App edits must publish canonical sidecars")
        let revision = state.sharedLibrary.revision
        let coordinator = state.sharedLibrary.coordinator!
        let peer = SharedLibraryCoordinator(root: root, writerID: coordinator.writerID, witnessDirectory: witnesses)
        let before = try await peer.recording(at: "Meeting.mp3")
        _ = try await peer.edit(.init(base: before, changes: [.assign(field: "metadata.mode", value: .text("\"Mee\""))]))
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await state.library.store.mode(for: "Meeting.mp3") != "Mee" {
            guard ContinuousClock.now < deadline else { throw Failure(description: "Independent coordinator edit did not refresh app metadata") }
            try await Task.sleep(for: .milliseconds(10))
        }
        try expect(await state.library.store.mode(for: "Meeting.mp3") == "Mee", "Activation refresh must reread shared metadata")
        try expect(state.sharedLibrary.revision > revision, "Visible content must receive a new revision")
        guard let recording = state.library.recordings.first else { throw Failure(description: "Missing app recording") }
        await state.renameRecording(recording, to: "Renamed")
        try expect(state.errorMessage == nil, "App rename must not attempt duplicate legacy sidecar changes")
        try expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Renamed.summary.json").path), "App rename must preserve summary companion")
        let after = try await coordinator.recording(at: "Renamed.mp3")
        try expect(after.state.id == entity, "App rename must preserve recording identity")
        await state.sharedLibrary.close()
        let reopened = AppState(baseDirectory: root, sharedIdentity: identity, sharedWitnessDirectory: witnesses)
        try await reopened.setup()
        try expect(reopened.sharedLibrary.coordinator != nil, "Existing metadata must reconnect without re-enabling")
        try expect(reopened.library.recordings.map(\.filename) == ["Renamed.mp3"], "Reopened app must display current library")
        let secondRoot = parent.appendingPathComponent("second-mac")
        try FileManager.default.copyItem(at: root, to: secondRoot)
        let identityB: @Sendable () async throws -> SharedLibraryWriterIdentity = {
            try await SharedLibraryWriterIdentityStore(file: parent.appendingPathComponent("writer-B.json"), installationAnchor: "synthetic second installation").load()
        }
        let reader = AppState(baseDirectory: secondRoot, sharedIdentity: identityB, sharedWitnessDirectory: parent.appendingPathComponent("witnesses-B"))
        try await reader.setup()
        try expect(reader.sharedLibrary.phase == .readOnly, "Unenrolled Mac must read without writing")
        let provider = Provider()
        reader.summarizeRecordings(reader.library.recordings, template: TemplateStore.builtInDefaults[0], provider: provider, model: "fixture")
        let summaryDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while reader.summarization.isSummarizing {
            guard ContinuousClock.now < summaryDeadline else { throw Failure(description: "Readonly summary did not stop") }
            try await Task.sleep(for: .milliseconds(10))
        }
        try expect(await provider.calls == 0, "Readonly app must reject a job before contacting even a synthetic LLM")
        try await reader.sharedLibrary.requestAccess()
        try expect(reader.sharedLibrary.phase == .readOnly, "Joining must wait for existing Macs")
        await reader.sharedLibrary.close()
        let otherRoot = parent.appendingPathComponent("other-library")
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        try Data("Other synthetic audio".utf8).write(to: otherRoot.appendingPathComponent("Other.mp3"))
        try expect(await reopened.switchStorageLocation(to: .custom, customURL: otherRoot), "Shared-to-legacy switch must reconnect stores")
        try expect(reopened.sharedLibrary.coordinator == nil, "A new legacy folder must release the old binding")
        try expect(reopened.library.recordings.map(\.filename) == ["Other.mp3"], "New root must not show old library content")
        try expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Renamed.mp3").path), "Storage switching must not move recordings")
        await reopened.sharedLibrary.close()
        print("Actual shared AppState checks passed: explicit enable, identity isolation, semantic edits/publication, refresh, rename/companions and reconnect.")
    }
}
