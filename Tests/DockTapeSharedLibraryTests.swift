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
        let action: @Sendable () async throws -> Void
        init(action: @escaping @Sendable () async throws -> Void = {}) { self.action = action }
        func summarize(transcript: String, systemPrompt: String, model: String) async throws -> String {
            calls += 1
            try await action()
            return "Synthetic summary"
        }
    }
    actor Gate {
        var waiting = false
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async { waiting = true; await withCheckedContinuation { continuation = $0 } }
        func release() { continuation?.resume(); continuation = nil }
    }
    @MainActor static func main() async {
        do {
            if CommandLine.arguments.contains("--publication-overlap-only") {
                _ = NSApplication.shared
                UserDefaults.standard.setVolatileDomain(["storageMode": "local"], forName: UserDefaults.argumentDomain)
                let parent = FileManager.default.temporaryDirectory.appendingPathComponent("DockTapePublication-" + UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: parent) }
                try await publicationOverlapChecks(parent: parent)
            } else if CommandLine.arguments.contains("--refresh-notifications-only") {
                _ = NSApplication.shared
                UserDefaults.standard.setVolatileDomain(["storageMode": "local"], forName: UserDefaults.argumentDomain)
                let parent = FileManager.default.temporaryDirectory.appendingPathComponent("DockTapeRefresh-" + UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: parent) }
                try await refreshStatusChecks(parent: parent)
            } else { try await run() }
        }
        catch { fputs("Shared AppState checks failed: \(error)\n", stderr); exit(1) }
    }
    @MainActor static func run() async throws {
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
        let playbackCoordinator = state.sharedLibrary.coordinator!
        let gate = Gate()
        let heldPlayer = PlaybackState(prepareFile: { _, _ in await gate.wait(); return true })
        heldPlayer.acquireLease = { filename, _ in
            let view = try await playbackCoordinator.recording(at: filename)
            let token = try await playbackCoordinator.pinJob(.init(id: view.state.id, kind: .recording))
            return .init(validate: { try await playbackCoordinator.validateJob(token) }, release: { await playbackCoordinator.finishJob(token) })
        }
        heldPlayer.play(file: "Meeting.mp3", url: root.appendingPathComponent("Meeting.mp3"))
        let playerDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await gate.waiting) {
            guard ContinuousClock.now < playerDeadline else { throw Failure(description: "Playback preparation did not start") }
            try await Task.sleep(for: .milliseconds(10))
        }
        let observer = SharedLibraryCoordinator(root: root, writerID: playbackCoordinator.writerID, witnessDirectory: witnesses)
        let protected = try await observer.operationAuthority(entity: .init(id: entity, kind: .recording), paths: ["Meeting.mp3"])
        try expect(protected.hasPendingWork, "Playback preparation must protect the original across instances")
        heldPlayer.stop()
        let releaseDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while try await observer.operationAuthority(entity: .init(id: entity, kind: .recording), paths: ["Meeting.mp3"]).hasPendingWork {
            guard ContinuousClock.now < releaseDeadline else { throw Failure(description: "Playback stop did not release lease") }
            try await Task.sleep(for: .milliseconds(10))
        }
        await gate.release()
        _ = try await state.library.transcriptStore.loadTranscript(for: "Meeting.mp3")
        try await state.library.updateSpeakerNames(for: "Meeting.mp3", names: ["s": "Alice"])
        await state.refreshAll()
        let transcriptFile = root.appendingPathComponent("Meeting.transcript.json")
        var json = try Data(contentsOf: transcriptFile)
        let publicationDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !String(decoding: json, as: UTF8.self).contains("Alice"),
              ContinuousClock.now < publicationDeadline {
            try await Task.sleep(for: .milliseconds(10))
            json = try Data(contentsOf: transcriptFile)
        }
        try expect(String(decoding: json, as: UTF8.self).contains("Alice"), "App edits must publish canonical sidecars without another refresh")
        let revision = state.sharedLibrary.revision
        let coordinator = state.sharedLibrary.coordinator!
        let peer = SharedLibraryCoordinator(root: root, writerID: coordinator.writerID, witnessDirectory: witnesses)
        let before = try await peer.recording(at: "Meeting.mp3")
        _ = try await peer.edit(.init(base: before, changes: [.assign(field: "metadata.mode", value: .text("\"Mee\""))]))
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await state.library.store.mode(for: "Meeting.mp3") != "Mee" || state.sharedLibrary.revision <= revision {
            guard ContinuousClock.now < deadline else { throw Failure(description: "Independent coordinator edit did not refresh app metadata") }
            try await Task.sleep(for: .milliseconds(10))
        }
        try expect(await state.library.store.mode(for: "Meeting.mp3") == "Mee", "Activation refresh must reread shared metadata")
        try expect(state.sharedLibrary.revision > revision, "Visible content must receive a new revision")
        guard let recording = state.library.recordings.first else { throw Failure(description: "Missing app recording") }
        await state.renameRecording(recording, to: "Renamed")
        let renameOutcome = await state.library.store.sharedOperation
        try expect(state.errorMessage == nil, "App rename must not attempt duplicate legacy sidecar changes: " + (state.errorMessage ?? "no error") + "; result=\(String(describing: renameOutcome?.result)); projection=\(String(describing: renameOutcome?.projectionError))")
        try expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Renamed.summary.json").path), "App rename must preserve summary companion")
        let after = try await coordinator.recording(at: "Renamed.mp3")
        try expect(after.state.id == entity, "App rename must preserve recording identity")
        let baseline = try await coordinator.read(.init(id: entity, kind: .recording))
        let oldSummaryID = baseline.state.currentDocument(for: .summary)?.id
        let staleProvider = Provider(action: {
            let current = try await coordinator.read(.init(id: entity, kind: .recording))
            let newer = Transcript(recordingFilename: "Renamed.mp3", transcriptionModel: "new input", hasSpeakerLabels: false,
                segments: [.init(startTime: 0, endTime: 1, text: "Changed input")])
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            _ = try await coordinator.edit(.init(base: current, changes: [.generation(try SharedDocument(id: UUID(), json: encoder.encode(newer)), component: .transcript)]))
        })
        _ = try await state.summarization.summaryStore.loadSummary(for: "Renamed.mp3")
        state.summarizeRecordings(state.library.recordings, template: TemplateStore.builtInDefaults[0], provider: staleProvider, model: "fixture")
        let raceDeadline = ContinuousClock.now.advanced(by: .seconds(4))
        while state.summarization.isSummarizing {
            guard ContinuousClock.now < raceDeadline else { throw Failure(description: "Summary race timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
        try expect(await staleProvider.calls == 1, "Ready summary race must reach the synthetic provider: " + (state.errorMessage ?? "no error"))
        let raced = try await coordinator.read(.init(id: entity, kind: .recording))
        try expect(raced.state.currentDocument(for: .summary)?.id == oldSummaryID, "Actual summary queue must not save output from an old transcript")
        state.errorMessage = nil
        let validProvider = Provider()
        state.summarizeRecordings(state.library.recordings, template: TemplateStore.builtInDefaults[0], provider: validProvider, model: "fixture")
        let validDeadline = ContinuousClock.now.advanced(by: .seconds(4))
        while state.summarization.isSummarizing {
            guard ContinuousClock.now < validDeadline else { throw Failure(description: "Valid summary timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
        let completed = try await coordinator.read(.init(id: entity, kind: .recording))
        try expect(completed.state.currentDocument(for: .summary)?.id != oldSummaryID && state.errorMessage == nil, "Valid app summary must publish once from its pinned transcript")
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
        try await mergeSelectionChecks(parent: parent, identity: identity)
        try await folderRenameChecks(parent: parent, identity: identity)
        try await folderDeleteLibraryChecks(parent: parent)
        try await refreshStatusChecks(parent: parent)
        try await retainedDeletionVisibilityChecks(parent: parent, identity: identity)
        try await publicationOverlapChecks(parent: parent.appendingPathComponent("publication-overlap"))
        print("Actual shared AppState checks passed: explicit enable, identity isolation, semantic edits/publication, refresh, rename/companions, reconnect and ID-bound merge/original deletion and folder rename/delete.")
    }
    @MainActor static func publicationOverlapChecks(parent: URL) async throws {
        let root = parent.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("synthetic publication audio".utf8).write(to: root.appendingPathComponent("Meeting.mp3"))
        try await TranscriptStore(baseDirectory: root).save(Transcript(recordingFilename: "Meeting.mp3", transcriptionModel: "fixture", hasSpeakerLabels: true,
            segments: [.init(startTime: 0, endTime: 1, text: "Synthetic publication", speakerID: "s")]), mp3Filename: "Meeting.mp3")
        let identity = try await SharedLibraryWriterIdentityStore(file: parent.appendingPathComponent("identity.json"), installationAnchor: "publication fixture").load()
        let witnesses = parent.appendingPathComponent("witnesses")
        let seed = SharedLibraryCoordinator(root: root, writerID: identity.writer, witnessDirectory: witnesses)
        _ = try await seed.enable(); _ = try await seed.projectOutputs()
        let original = try await seed.recording(at: "Meeting.mp3")
        guard let generation = original.state.currentDocument(for: .transcript) else { throw Failure(description: "Missing publication fixture transcript") }
        _ = try await seed.edit(.init(base: original, changes: [.generationEdit(component: .transcript, generation: generation.id, key: "s", value: .text("Alice"))]))
        let state = AppState(baseDirectory: root, sharedIdentity: { identity }, sharedWitnessDirectory: witnesses)
        try await state.setup()
        await state.sharedLibrary.coordinator?.stopMonitoring()
        let olderGate = Gate(), newerGate = Gate()
        let older = Task { @MainActor in await state.refreshAll(refreshShared: false, beforePublication: { await olderGate.wait() }) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await olderGate.waiting) {
            guard ContinuousClock.now < deadline else { throw Failure(description: "Older publication did not reach barrier") }
            try await Task.sleep(for: .milliseconds(10))
        }
        let newer = Task { @MainActor in await state.refreshAll(refreshShared: false, beforePublication: { await newerGate.wait() }) }
        while !(await newerGate.waiting) {
            guard ContinuousClock.now < deadline else { throw Failure(description: "Newer publication did not reach barrier") }
            try await Task.sleep(for: .milliseconds(10))
        }
        await olderGate.release(); await older.value
        let file = root.appendingPathComponent("Meeting.transcript.json")
        let immediate = String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("Alice")
        try expect(!immediate, "A superseded request can return while the actual canonical publication is still pending")
        await newerGate.release(); await newer.value
        let current = String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("Alice")
        try expect(current, "The current refresh must publish the accepted semantic edit")
        await state.sharedLibrary.close()
        print("Actual publication overlap passed: superseded return precedes canonical output; current refresh publishes accepted edit.")
    }

    @MainActor static func retainedDeletionVisibilityChecks(parent: URL, identity: @escaping @Sendable () async throws -> SharedLibraryWriterIdentity) async throws {
        let root = parent.appendingPathComponent("retained-deletion")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let audio = Data("synthetic retained original".utf8)
        try audio.write(to: root.appendingPathComponent("Meeting.mp3"))
        let witnesses = parent.appendingPathComponent("retained-deletion-witnesses")
        let refuseTrash: @Sendable (URL) throws -> Void = { _ in throw Failure(description: "Pending fixture must never attempt disposal") }
        let state = AppState(baseDirectory: root, sharedIdentity: identity, sharedWitnessDirectory: witnesses, sharedTrash: refuseTrash)
        try await state.setup()
        try expect(await state.enableSharedLibrary(), "Enable retained-deletion app fixture")
        guard let coordinator = state.sharedLibrary.coordinator else { throw Failure(description: "Missing retained-deletion binding") }
        await coordinator.stopMonitoring()
        let original = try await coordinator.recording(at: "Meeting.mp3")
        let token = try await coordinator.pinJob(.init(id: original.state.id, kind: .recording))
        let pending = try await coordinator.deleteSharedRecording(filename: "Meeting.mp3")
        try expect(pending.result == .waitingForAcknowledgments, "An active job must retain the original after logical deletion")
        await state.library.refresh()
        try expect(state.library.recordings.isEmpty, "The actual library list must hide the accepted deletion while the original remains")
        try expect(try Data(contentsOf: root.appendingPathComponent("Meeting.mp3")) == audio, "Visibility must never dispose or rewrite retained media")
        await state.sharedLibrary.close()
        let reopened = AppState(baseDirectory: root, sharedIdentity: identity, sharedWitnessDirectory: witnesses, sharedTrash: refuseTrash)
        try await reopened.setup()
        try expect(reopened.library.recordings.isEmpty, "Fresh launch must not rediscover a pending-deleted original as a new recording")
        await reopened.sharedLibrary.close()
        await coordinator.finishJob(token)
        print("Actual retained-deletion visibility passed: refresh and fresh launch hide pending original; audio unchanged.")
    }

    @MainActor static func mergeSelectionChecks(parent: URL, identity: @escaping @Sendable () async throws -> SharedLibraryWriterIdentity) async throws {
        let root = parent.appendingPathComponent("merge-library")
        let legacy = RecordingStore(baseDirectory: root)
        try await legacy.setup()
        var bytes = Data(repeating: 0, count: 417)
        bytes.replaceSubrange(0..<4, with: [0xFF, 0xFB, 0x90, 0x64])
        for name in ["A", "B"] { _ = try await legacy.importRecording(hdaData: bytes, entry: FileEntry(filename: name + ".hda", size: UInt32(bytes.count))) }
        let state = AppState(baseDirectory: root, sharedIdentity: identity, sharedWitnessDirectory: parent.appendingPathComponent("merge-witnesses"))
        try await state.setup()
        try expect(await state.enableSharedLibrary(), "Enable isolated merge library")
        await state.sharedLibrary.coordinator?.stopMonitoring()
        state.library.selectedRecordings = ["A.mp3", "B.mp3"]
        state.startMerge()
        _ = try await state.library.store.renameRecording(filename: "B.mp3", to: "Current B")
        await state.executeMerge(as: "Joined")
        try expect(state.showMergeDeletePrompt && FileManager.default.fileExists(atPath: root.appendingPathComponent("Joined.mp3").path), "Actual merge dialog must follow selected IDs after rename: " + (state.errorMessage ?? ""))
        try expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("B.mp3").path), "Merge must not recreate the old source name")
        guard let shared = state.sharedLibrary.coordinator else { throw Failure(description: "Missing merge coordinator") }
        let oldB = try await shared.reference(to: "Current B.mp3")
        let oldA = try await shared.reference(to: "A.mp3")
        _ = try await state.library.store.renameRecording(filename: "Current B.mp3", to: "Later B")
        _ = try await state.library.store.importRecording(hdaData: bytes, entry: FileEntry(filename: "Unrelated.hda", size: UInt32(bytes.count)))
        _ = try await state.library.store.renameRecording(filename: "Unrelated.mp3", to: "B")
        let unrelated = try await shared.reference(to: "B.mp3")
        var held: [SharedLibraryJobToken] = []
        // Veto physical disposal for every possible target, so the assertion
        // cannot send even a failing test's fixtures to the user's Trash.
        for (reference, path) in [(oldA, "A.mp3"), (oldB, "Later B.mp3"), (unrelated, "B.mp3")] {
            held.append(try await shared.pinJob(.init(id: reference.entityID, kind: .recording), audioURL: root.appendingPathComponent(path)))
        }
        await state.deleteMergeOriginals()
        let deletedOriginal = try await shared.read(.init(id: oldB.entityID, kind: .recording))
        let preservedNew = try await shared.read(.init(id: unrelated.entityID, kind: .recording))
        try expect(deletedOriginal.state.lifecycle == .deleted && preservedNew.state.lifecycle == .alive, "Delete originals must follow IDs and leave a new recording at the old filename alone: " + (state.errorMessage ?? "no error") + " original=\(deletedOriginal.state.lifecycle) unrelated=\(preservedNew.state.lifecycle)")
        for path in ["A.mp3", "Later B.mp3", "B.mp3"] {
            try expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path), "Active fixture leases must veto physical disposal")
        }
        for token in held { await shared.finishJob(token) }
        state.library.selectedRecordings = ["B.mp3", "Joined.mp3"]
        state.startMerge()
        let other = parent.appendingPathComponent("merge-other-library")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        for name in ["B", "Joined"] { try bytes.write(to: other.appendingPathComponent(name + ".mp3")) }
        try expect(await state.switchStorageLocation(to: .custom, customURL: other), "Switch isolated merge library")
        await state.executeMerge(as: "Wrong library")
        try expect(!FileManager.default.fileExists(atPath: other.appendingPathComponent("Wrong library.mp3").path), "A changed library must invalidate the open merge dialog")
        try expect(state.errorMessage?.contains("library changed") == true, "Explain the changed merge binding")
        await state.sharedLibrary.close()
    }

    @MainActor static func folderRenameChecks(parent: URL, identity: @escaping @Sendable () async throws -> SharedLibraryWriterIdentity) async throws {
        let root = parent.appendingPathComponent("folder-library")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Folder/Nested"), withIntermediateDirectories: true)
        for name in ["Folder/A.mp3", "Folder/Nested/B.mp3"] { try Data("synthetic folder audio".utf8).write(to: root.appendingPathComponent(name)) }
        let legacy = RecordingStore(baseDirectory: root)
        try await legacy.setup()
        try await TranscriptStore(baseDirectory: root).save(Transcript(recordingFilename: "Folder/A.mp3", transcriptionModel: "fixture", hasSpeakerLabels: false,
            segments: [.init(startTime: 0, endTime: 1, text: "Preserved")]), mp3Filename: "Folder/A.mp3")
        let state = AppState(baseDirectory: root, sharedIdentity: identity, sharedWitnessDirectory: parent.appendingPathComponent("folder-witnesses"))
        try await state.setup()
        try expect(await state.enableSharedLibrary(), "Enable isolated folder library")
        guard let shared = state.sharedLibrary.coordinator else { throw Failure(description: "Missing folder coordinator") }
        await shared.stopMonitoring()
        let reference = try await shared.reference(to: "Folder/A.mp3")
        state.selectedView = .folder("Folder")
        state.library.selectedFolder = "Folder"
        await state.renameFolder(from: "Folder", to: "Renamed")
        try expect(state.errorMessage == nil && state.selectedView == .folder("Renamed") && state.library.selectedFolder == "Renamed", "Actual folder action must retarget sidebar selection: " + (state.errorMessage ?? ""))
        try expect(Set(state.library.recordings.map(\.filename)) == ["Renamed/A.mp3", "Renamed/Nested/B.mp3"], "Actual app must refresh all renamed descendant paths")
        try expect(try await shared.reference(to: "Renamed/A.mp3") == reference, "App folder action must preserve child IDs")
        let transcript = await state.transcription.transcriptStore.transcript(for: "Renamed/A.mp3")
        try expect(transcript?.recordingFilename == "Renamed/A.mp3", "Actual transcript adapter must read the relocated companion")
        await state.sharedLibrary.close()
    }

    @MainActor static func folderDeleteLibraryChecks(parent: URL) async throws {
        let root = parent.appendingPathComponent("folder-delete-library")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Folder/Nested"), withIntermediateDirectories: true)
        for name in ["Folder/A.mp3", "Folder/Nested/B.mp3"] { try Data("synthetic deletion audio".utf8).write(to: root.appendingPathComponent(name)) }
        let legacy = RecordingStore(baseDirectory: root)
        try await legacy.setup()
        let recycled = parent.appendingPathComponent("folder-delete-recycled")
        let identity: @Sendable () async throws -> SharedLibraryWriterIdentity = {
            try await SharedLibraryWriterIdentityStore(file: parent.appendingPathComponent("folder-delete-writer.json"), installationAnchor: "synthetic deletion installation").load()
        }
        let state = AppState(baseDirectory: root, sharedIdentity: identity, sharedWitnessDirectory: parent.appendingPathComponent("folder-delete-witnesses"), sharedTrash: { url in
            try FileManager.default.createDirectory(at: recycled, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: recycled.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent))
        })
        try await state.setup()
        try expect(await state.enableSharedLibrary(), "Enable actual app deletion library")
        await state.sharedLibrary.coordinator?.stopMonitoring()
        state.library.selectedFolder = "Folder"
        state.selectedView = .folder("Folder")
        await state.deleteFolder(named: "Folder")
        try expect(state.errorMessage == nil && state.selectedView == .allRecordings && state.library.selectedFolder == nil && state.library.folders.isEmpty && state.library.recordings.isEmpty, "Actual app action must clear the removed folder and refresh descendants: " + (state.errorMessage ?? ""))
        try expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Folder").path), "Actual app action must complete acknowledged empty-directory cleanup")
        await state.sharedLibrary.close()
    }

    @MainActor static func refreshStatusChecks(parent: URL) async throws {
        let root = parent.appendingPathComponent("refresh-status")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("synthetic refresh audio".utf8).write(to: root.appendingPathComponent("Meeting.mp3"))
        try await TranscriptStore(baseDirectory: root).save(Transcript(recordingFilename: "Meeting.mp3", transcriptionModel: "fixture", hasSpeakerLabels: false,
            segments: [.init(startTime: 0, endTime: 1, text: "Current synthetic transcript")]), mp3Filename: "Meeting.mp3")
        let identityFile = parent.appendingPathComponent("refresh-identity.json")
        let identity = try await SharedLibraryWriterIdentityStore(file: identityFile, installationAnchor: "refresh fixture").load()
        let witness = parent.appendingPathComponent("refresh-witnesses")
        let seed = SharedLibraryCoordinator(root: root, writerID: identity.writer, witnessDirectory: witness)
        _ = try await seed.enable(); try await seed.refresh(); _ = try await seed.projectOutputs()
        let state = AppState(baseDirectory: root, sharedIdentity: { identity }, sharedWitnessDirectory: witness)
        try await state.setup()
        await state.sharedLibrary.coordinator?.stopMonitoring()
        let held = Gate()
        let older = Task { @MainActor in
            await state.refreshAll(refreshShared: false, beforePublication: {
                await held.wait()
                throw SharedProjectionWriteError.stale
            })
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await held.waiting) {
            guard ContinuousClock.now < deadline else { throw Failure(description: "Old refresh did not reach publication") }
            try await Task.sleep(for: .milliseconds(10))
        }
        let file = root.appendingPathComponent("Meeting.transcript.json")
        let external = Data("{damaged external synthetic sidecar".utf8)
        try external.write(to: file, options: .atomic)
        await state.refreshAll(refreshShared: false)
        let currentMessage = state.sharedLibrary.message
        try expect(currentMessage?.contains("External Files") == true, "Newest refresh must report actual untracked sidecar")
        await held.release(); await older.value
        try expect(state.sharedLibrary.message == currentMessage, "Old refresh failure must not overwrite the newest actionable message")
        try expect(try Data(contentsOf: file) == external, "Refresh feedback must never overwrite external bytes")
        await state.refreshAll(refreshShared: false, beforePublication: { throw SharedProjectionWriteError.stale })
        try expect(state.sharedLibrary.message != nil, "A current refresh failure remains visible")
        let cancelledGate = Gate()
        let savedMessage = state.sharedLibrary.message
        let cancelled = Task { @MainActor in
            await state.refreshAll(refreshShared: false, beforePublication: {
                await cancelledGate.wait(); throw CancellationError()
            })
        }
        let cancelDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await cancelledGate.waiting) {
            guard ContinuousClock.now < cancelDeadline else { throw Failure(description: "Cancelled refresh did not reach publication") }
            try await Task.sleep(for: .milliseconds(10))
        }
        cancelled.cancel(); await cancelledGate.release(); await cancelled.value
        try expect(state.sharedLibrary.message == savedMessage, "Cancelled refresh cannot replace current feedback")
        // Returning from an older awaited request does not mean a newer
        // request has finished publishing its feedback.
        state.sharedLibrary.message = nil
        let olderGate = Gate(), currentGate = Gate()
        let superseded = Task { @MainActor in
            await state.refreshAll(refreshShared: false, beforePublication: { await olderGate.wait() })
        }
        let olderDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await olderGate.waiting) {
            guard ContinuousClock.now < olderDeadline else { throw Failure(description: "Superseded request did not reach publication") }
            try await Task.sleep(for: .milliseconds(10))
        }
        let current = Task { @MainActor in
            await state.refreshAll(refreshShared: false, beforePublication: { await currentGate.wait() })
        }
        let currentDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await currentGate.waiting) {
            guard ContinuousClock.now < currentDeadline else { throw Failure(description: "Current request did not reach publication") }
            try await Task.sleep(for: .milliseconds(10))
        }
        await olderGate.release(); await superseded.value
        try expect(state.sharedLibrary.message == nil, "Older request must return without claiming the current request's result")
        await currentGate.release(); await current.value
        try expect(state.sharedLibrary.message?.contains("External Files") == true, "The newer request must eventually publish actionable recovery feedback")
        try expect(try Data(contentsOf: file) == external, "Overlapping refreshes must preserve external bytes")
        await state.sharedLibrary.close()
        print("Actual refresh status ordering passed: late/cancelled failures cannot overwrite current external-file review; current failures remain visible; superseded requests return before newer feedback.")

        let entity = SharedEntityIdentity(id: try await seed.recording(at: "Meeting.mp3").state.id, kind: .recording)
        let reviews = try await seed.reviewSidecars(entity)
        guard let review = reviews.first else { throw Failure(description: "Missing known synthetic damage") }
        _ = try await seed.recoverSidecar(review, useChangedFile: false)
        try await seed.refresh(); _ = try await seed.projectOutputs()
        try await seed.refresh(); _ = try await seed.projectOutputs()
        let observing = AppState(baseDirectory: root, sharedIdentity: { identity }, sharedWitnessDirectory: witness)
        try await observing.setup()
        try expect(observing.sharedLibrary.message == nil, "Fresh bound app starts without an external-file error")
        let stream = await observing.sharedLibrary.coordinator!.events()
        var observedEvents: [String] = []
        let events = Task { @MainActor in
            for await event in stream {
                switch event {
                case .files: observedEvents.append("files")
                case .entity: observedEvents.append("entity")
                case .failure(let error): observedEvents.append("error: " + error)
                case .loading: break
                }
            }
        }
        defer { events.cancel() }
        let liveExternal = Data("{new distinct external sidecar occurrence".utf8)
        try await CoordinatedFileAccess().withWrite(at: file) { scope in
            try scope.checkCancellation(); try liveExternal.write(to: scope.url, options: .atomic)
        }
        let notificationDeadline = ContinuousClock.now.advanced(by: .seconds(4))
        while observing.sharedLibrary.message?.contains("External Files") != true {
            guard ContinuousClock.now < notificationDeadline else { throw Failure(description: "Canonical sidecar-only change must notify the running app without Refresh or relaunch; message=\(observing.sharedLibrary.message ?? "none"); revision=\(observing.sharedLibrary.revision); events=\(observedEvents)") }
            try await Task.sleep(for: .milliseconds(20))
        }
        try expect(try Data(contentsOf: file) == liveExternal, "Live external detection preserves the changed file")
        var revisions: [UInt64] = []
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(100))
            revisions.append(observing.sharedLibrary.revision)
        }
        print("Post-notification revisions: \(revisions)")
        try expect(Set(revisions.suffix(6)).count == 1, "External notifications must settle without a no-op publication loop: \(revisions)")
        await observing.sharedLibrary.close()
        print("Actual live sidecar notification passed without explicit refresh or relaunch.")
        let interruptedRoot = parent.appendingPathComponent("interrupted-bootstrap")
        try FileManager.default.createDirectory(at: interruptedRoot, withIntermediateDirectories: true)
        try Data("synthetic bootstrap audio".utf8).write(to: interruptedRoot.appendingPathComponent("Meeting.mp3"))
        try await TemplateStore(baseDirectory: interruptedRoot).update(TemplateStore.builtInDefaults[0])
        let interruptedWitness = parent.appendingPathComponent("bootstrap-witness")
        let interrupted = SharedLibraryCoordinator(root: interruptedRoot, writerID: identity.writer, witnessDirectory: interruptedWitness)
        _ = try await interrupted.enable()
        do { _ = try await interrupted.projectOutputs(beforeOutput: { index in if index == 1 { throw CancellationError() } }); throw Failure(description: "Expected publication interruption") }
        catch is CancellationError {}
        let recovering = AppState(baseDirectory: interruptedRoot, sharedIdentity: { identity }, sharedWitnessDirectory: interruptedWitness)
        try await recovering.setup()
        guard let recovery = recovering.sharedLibrary.coordinator else { throw Failure(description: "Missing bootstrap recovery binding") }
        await recovery.stopMonitoring()
        let model = recovering.sharedLibrary.externalReview
        await model.refresh(using: recovery)
        guard let row = model.items.first(where: { $0.bootstrap?.filename == ".templates.json" }) else { throw Failure(description: "Interrupted templates must have an actionable restore row") }
        try expect(await model.apply(row, useChangedFile: false, using: recovery), "Actual review model must restore an interrupted aggregate")
        await recovering.refreshAll()
        await model.refresh(using: recovery)
        try expect(model.items.isEmpty && recovering.sharedLibrary.message == nil, "Aggregate recovery must clear its row and app feedback")
        await recovering.sharedLibrary.close()
        print("Actual AppState interrupted-bootstrap review and restoration passed.")
    }

}
