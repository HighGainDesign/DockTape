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
            if CommandLine.arguments.contains("--folder-selection-only") {
                _ = NSApplication.shared
                UserDefaults.standard.setVolatileDomain(["storageMode": "local"], forName: UserDefaults.argumentDomain)
                let parent = FileManager.default.temporaryDirectory.appendingPathComponent("DockTapeFolderSelection-" + UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: parent) }
                try await folderSelectionChecks(parent: parent)
                try await capturedFolderSelectionChecks(parent: parent.appendingPathComponent("captured"))
            } else if CommandLine.arguments.contains("--background-metadata-only") {
                _ = NSApplication.shared
                UserDefaults.standard.setVolatileDomain(["storageMode": "local"], forName: UserDefaults.argumentDomain)
                let parent = FileManager.default.temporaryDirectory.appendingPathComponent("DockTapeBackgroundMetadata-" + UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: parent) }
                try await backgroundMetadataChecks(parent: parent)
            } else if CommandLine.arguments.contains("--folder-rename-only") {
                _ = NSApplication.shared
                UserDefaults.standard.setVolatileDomain(["storageMode": "local"], forName: UserDefaults.argumentDomain)
                let parent = FileManager.default.temporaryDirectory.appendingPathComponent("DockTapeFolderRename-" + UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: parent) }
                let identity: @Sendable () async throws -> SharedLibraryWriterIdentity = { try await SharedLibraryWriterIdentityStore(file: parent.appendingPathComponent("identity.json"), installationAnchor: "rename fixture").load() }
                for index in 0..<8 { try await folderRenameChecks(parent: parent.appendingPathComponent(String(index)), identity: identity) }
            } else if CommandLine.arguments.contains("--cold-metadata-retry-only") {
                _ = NSApplication.shared
                UserDefaults.standard.setVolatileDomain(["storageMode": "local"], forName: UserDefaults.argumentDomain)
                let parent = FileManager.default.temporaryDirectory.appendingPathComponent("DockTapeColdMetadataRetry-" + UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: parent) }
                try await coldMetadataRetryChecks(parent: parent)
            } else if CommandLine.arguments.contains("--cold-metadata-refresh-only") {
                _ = NSApplication.shared
                UserDefaults.standard.setVolatileDomain(["storageMode": "local"], forName: UserDefaults.argumentDomain)
                let parent = FileManager.default.temporaryDirectory.appendingPathComponent("DockTapeColdMetadataRefresh-" + UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: parent) }
                try await coldMetadataRefreshChecks(parent: parent)
            } else if CommandLine.arguments.contains("--cold-metadata-only") {
                _ = NSApplication.shared
                UserDefaults.standard.setVolatileDomain(["storageMode": "local"], forName: UserDefaults.argumentDomain)
                let parent = FileManager.default.temporaryDirectory.appendingPathComponent("DockTapeColdMetadata-" + UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: parent) }
                for action in [ColdMetadataAction.complete, .stop, .switchLibrary] {
                    try await coldMetadataStartupChecks(parent: parent.appendingPathComponent(String(describing: action)), deletedOnly: CommandLine.arguments.contains("--deleted-only"), action: action)
                }
            } else if CommandLine.arguments.contains("--delete-selection-only") {
                _ = NSApplication.shared
                UserDefaults.standard.setVolatileDomain(["storageMode": "local"], forName: UserDefaults.argumentDomain)
                let parent = FileManager.default.temporaryDirectory.appendingPathComponent("DockTapeDeleteSelection-" + UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: parent) }
                try await deleteSelectionChecks(parent: parent)
            } else if CommandLine.arguments.contains("--pending-delete-only") {
                _ = NSApplication.shared
                UserDefaults.standard.setVolatileDomain(["storageMode": "local"], forName: UserDefaults.argumentDomain)
                let parent = FileManager.default.temporaryDirectory.appendingPathComponent("DockTapePendingDelete-" + UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: parent) }
                let identity: @Sendable () async throws -> SharedLibraryWriterIdentity = {
                    try await SharedLibraryWriterIdentityStore(file: parent.appendingPathComponent("identity.json"), installationAnchor: "pending-delete fixture").load()
                }
                try await retainedDeletionVisibilityChecks(parent: parent, identity: identity)
                try await deleteSelectionChecks(parent: parent.appendingPathComponent("delete-selection"))
            } else if CommandLine.arguments.contains("--publication-overlap-only") {
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
        try await folderSelectionChecks(parent: parent.appendingPathComponent("folder-selection"))
        try await capturedFolderSelectionChecks(parent: parent.appendingPathComponent("folder-captured"))
        try await folderRenameChecks(parent: parent, identity: identity)
        try await folderDeleteLibraryChecks(parent: parent)
        try await refreshStatusChecks(parent: parent)
        try await retainedDeletionVisibilityChecks(parent: parent, identity: identity)
        try await deleteSelectionChecks(parent: parent.appendingPathComponent("delete-selection"))
        try await publicationOverlapChecks(parent: parent.appendingPathComponent("publication-overlap"))
        try await coldMetadataStartupChecks(parent: parent.appendingPathComponent("cold-metadata"))
        try await coldMetadataStartupChecks(parent: parent.appendingPathComponent("cold-stop"), action: .stop)
        try await coldMetadataStartupChecks(parent: parent.appendingPathComponent("cold-switch"), action: .switchLibrary)
        try await coldMetadataRefreshChecks(parent: parent.appendingPathComponent("cold-refresh"))
        try await coldMetadataRetryChecks(parent: parent.appendingPathComponent("cold-retry"))
        try await backgroundMetadataChecks(parent: parent.appendingPathComponent("background-metadata"))
        try await backgroundMetadataChecks(parent: parent.appendingPathComponent("background-stop"), stop: true)
        print("Actual shared AppState checks passed: explicit enable, identity isolation, semantic edits/publication, refresh, rename/companions, reconnect and ID-bound merge/original deletion and folder rename/delete.")
    }
    @MainActor static func backgroundMetadataChecks(parent: URL, stop: Bool = false) async throws {
        let root = parent.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("Synthetic background refresh audio".utf8).write(to: root.appendingPathComponent("B.mp3"))
        let identity = try await SharedLibraryWriterIdentityStore(file: parent.appendingPathComponent("identity.json"), installationAnchor: "background fixture").load()
        let seed = SharedLibraryCoordinator(root: root, writerID: identity.writer, witnessDirectory: parent.appendingPathComponent("witnesses"))
        _ = try await seed.enable(); _ = try await seed.projectOutputs()
        let state = AppState(baseDirectory: root, sharedIdentity: { identity }, sharedWitnessDirectory: parent.appendingPathComponent("witnesses"))
        try await state.setup()
        await state.sharedLibrary.coordinator?.stopMonitoring()
        let gate = Gate()
        var cancelled = false
        let owner = Task { await state.library.refresh(afterMetadata: { await gate.wait(); cancelled = Task.isCancelled }) }
        while !(await gate.waiting) { try await Task.sleep(for: .milliseconds(10)) }
        var backgroundEntered = false
        let background = Task { await state.refreshAll(refreshShared: false, monitored: true, beforePublication: { backgroundEntered = true }) }
        for _ in 0..<50 {
            if backgroundEntered { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        if stop || CommandLine.arguments.contains("--stop-background") {
            state.library.cancelMetadataLoad()
            await background.value
            let stayedStopped = state.library.metadataLoadState == .stopped
            await gate.release(); _ = await owner.value
            await state.sharedLibrary.close()
            try expect(stayedStopped && !backgroundEntered, "An already queued watcher must not restart loading after Stop without Retry")
            print("Actual background stop passed: queued monitor respects Stop until explicit Retry.")
            return
        }
        await gate.release()
        let ownerCompleted = await owner.value
        await background.value
        await state.sharedLibrary.close()
        try expect(!cancelled && ownerCompleted, "A monitored refresh must not supersede the metadata load awaited by an interactive action")
        try expect(backgroundEntered && state.library.recordings.map(\.filename) == ["B.mp3"], "Queued monitor refresh must still execute after the interactive load")
        print("Actual background metadata passed: monitor refresh waits for interactive load without cancelling it.")
    }

    @MainActor static func coldMetadataRetryChecks(parent: URL) async throws {
        let root = parent.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["A.mp3", "B.mp3"] { try Data("Retry synthetic original".utf8).write(to: root.appendingPathComponent(name)) }
        var template = TemplateStore.builtInDefaults[0]; template.promptText = "Resident retry template override"
        try await TemplateStore(baseDirectory: root).update(template)
        let identity = try await SharedLibraryWriterIdentityStore(file: parent.appendingPathComponent("identity.json"), installationAnchor: "retry metadata fixture").load()
        let seed = SharedLibraryCoordinator(root: root, writerID: identity.writer, witnessDirectory: parent.appendingPathComponent("witnesses"))
        _ = try await seed.enable(); _ = try await seed.projectOutputs()
        let a = try await seed.reference(to: "A.mp3")
        let head = root.appendingPathComponent(".docktape/records/" + a.entityID.uuidString.lowercased() + "/" + identity.writer.uuidString.lowercased() + ".json")
        let original = try Data(contentsOf: head)
        try Data("Malformed retry fixture head".utf8).write(to: head, options: .atomic)
        let state = AppState(baseDirectory: root, sharedIdentity: { identity }, sharedWitnessDirectory: parent.appendingPathComponent("witnesses"))
        var failed = false
        do { try await state.setup() } catch { failed = true }
        let partial = state.library.recordings.map(\.filename)
        let errorVisible = state.library.refreshError != nil && !state.library.isLoadingMetadata
        try original.write(to: head, options: .atomic)
        let retried = await state.retryLibraryLoad()
        let restored = await state.templateStore.template(forID: template.id)
        let entries = Set(state.library.recordings.map(\.filename))
        await state.sharedLibrary.close()
        try expect(failed && errorVisible && partial == ["B.mp3"], "Invalid A metadata must report a real failure and preserve usable B")
        try expect(retried && entries == ["A.mp3", "B.mp3"], "Retry restores the complete recording list")
        try expect(restored?.promptText == template.promptText, "Retry must finish app setup, including the shared templates skipped by the failed startup")
        print("Actual cold metadata retry passed: corrupt A preserves B/error state; retry restores full app setup.")
    }

    @MainActor static func coldMetadataRefreshChecks(parent: URL) async throws {
        let root = parent.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["A.mp3", "B.mp3"] { try Data("Refresh synthetic original".utf8).write(to: root.appendingPathComponent(name)) }
        let identity = try await SharedLibraryWriterIdentityStore(file: parent.appendingPathComponent("identity.json"), installationAnchor: "refresh metadata fixture").load()
        let witnesses = parent.appendingPathComponent("witnesses")
        let seed = SharedLibraryCoordinator(root: root, writerID: identity.writer, witnessDirectory: witnesses)
        _ = try await seed.enable(); _ = try await seed.projectOutputs()
        let a = try await seed.reference(to: "A.mp3")
        let state = AppState(baseDirectory: root, sharedIdentity: { identity }, sharedWitnessDirectory: witnesses)
        try await state.setup()
        await state.sharedLibrary.coordinator?.stopMonitoring()
        let head = root.appendingPathComponent(".docktape/records/" + a.entityID.uuidString.lowercased() + "/" + identity.writer.uuidString.lowercased() + ".json")
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let holder = Task {
            try await CoordinatedFileAccess().withWrite(at: head) { _ in
                started.signal()
                guard release.wait(timeout: .now() + 15) == .success else { throw Failure(description: "Refresh head hold timed out") }
            }
        }
        let acquired = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: started.wait(timeout: .now() + 2) == .success) }
        }
        guard acquired else { release.signal(); _ = try? await holder.value; throw Failure(description: "Missing refresh head hold") }
        var finished = false
        let refreshing = Task { await state.refreshAll(); finished = true }
        for _ in 0..<100 {
            if state.library.isLoadingMetadata { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let waitingVisible = state.library.isLoadingMetadata
        let residentB = state.library.recordings.contains { $0.filename == "B.mp3" && $0.reference != nil }
        state.library.cancelMetadataLoad()
        for _ in 0..<100 {
            if finished { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let cancelledBeforeRelease = finished
        release.signal(); try await holder.value; await refreshing.value
        await state.sharedLibrary.close()
        try expect(waitingVisible, "An explicit app Refresh must show cancellable loading while A authority is held")
        try expect(residentB, "Existing verified B remains available during a refresh")
        try expect(cancelledBeforeRelease, "Stop Loading must cancel the entire refresh before held metadata is released")
        try expect(state.library.metadataLoadState == .stopped, "Late refresh completion must not clear the user's stopped state")
        print("Actual cold metadata refresh passed: waiting feedback, resident B and stop-before-release.")
    }

    enum ColdMetadataAction { case complete, stop, switchLibrary }
    @MainActor static func coldMetadataStartupChecks(parent: URL, deletedOnly: Bool = false, action: ColdMetadataAction = .complete) async throws {
        for deleted in deletedOnly ? [true] : [false, true] {
            let folder = parent.appendingPathComponent(deleted ? "deleted" : "alive")
            let root = folder.appendingPathComponent("library")
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Empty"), withIntermediateDirectories: true)
            for name in ["A.mp3", "B.mp3"] {
                try Data("synthetic cold metadata original".utf8).write(to: root.appendingPathComponent(name))
                try await TranscriptStore(baseDirectory: root).save(Transcript(recordingFilename: name, transcriptionModel: "fixture", hasSpeakerLabels: false,
                    segments: [.init(startTime: 0, endTime: 1, text: "Resident " + name)]), mp3Filename: name)
            }
            try await SummaryStore(baseDirectory: root).save(Summary(recordingFilename: "B.mp3", model: "fixture", provider: "fixture", templateUsed: "fixture",
                sections: [.init(heading: "Summary", content: "Resident B summary")]), mp3Filename: "B.mp3")
            let identity = try await SharedLibraryWriterIdentityStore(file: folder.appendingPathComponent("identity.json"), installationAnchor: "cold metadata fixture").load()
            let witnesses = folder.appendingPathComponent("witnesses")
            let seed = SharedLibraryCoordinator(root: root, writerID: identity.writer, witnessDirectory: witnesses)
            _ = try await seed.enable()
            let a = try await seed.recording(at: "A.mp3")
            if deleted { _ = try await seed.edit(.init(base: a, changes: [.delete])) }
            _ = try await seed.projectOutputs()
            let audioA = try Data(contentsOf: root.appendingPathComponent("A.mp3"))
            let head = root.appendingPathComponent(".docktape/records/" + a.state.id.uuidString.lowercased() + "/" + identity.writer.uuidString.lowercased() + ".json")
            let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            let holding = Task {
                try await CoordinatedFileAccess().withWrite(at: head) { _ in
                    started.signal()
                    guard release.wait(timeout: .now() + 15) == .success else { throw Failure(description: "Cold metadata fixture hold timed out") }
                }
            }
            let acquired = await withCheckedContinuation { continuation in
                DispatchQueue.global().async { continuation.resume(returning: started.wait(timeout: .now() + 2) == .success) }
            }
            guard acquired else { release.signal(); _ = try? await holding.value; throw Failure(description: "Fixture did not acquire A owner head") }
            let state = AppState(baseDirectory: root, sharedIdentity: { identity }, sharedWitnessDirectory: witnesses,
                sharedTrash: { _ in throw Failure(description: "Cold metadata fixture must never dispose an original") })
            var setupFinished = false
            let setup = Task { try await state.setup(); setupFinished = true }
            for _ in 0..<150 {
                if state.library.recordings.contains(where: { $0.filename == "B.mp3" }) && state.library.folderSelection(named: "Empty").reference != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let residentB = state.library.recordings.first { $0.filename == "B.mp3" }
            let emptyReady = state.library.folderSelection(named: "Empty").reference != nil
            let unknownAVisible = state.library.recordings.contains { $0.filename == "A.mp3" }
            let templatesBefore = state.sharedLibrary.revision
            let bContentID = state.library.contentID(for: "B.mp3", fallbackRevision: 0)
            let loadingVisible = state.library.isLoadingMetadata
            let badgesReady = state.transcription.statuses["B.mp3"] == .done && state.summarization.hasSummary.contains("B.mp3")
            var residentText: String?
            if residentB != nil { residentText = try await state.transcription.transcriptStore.loadTranscript(for: "B.mp3")?.segments.first?.text }
            var finishedBeforeRelease = true
            var switched = true
            var switchTask: Task<Bool, Never>?
            let other = folder.appendingPathComponent("other-library")
            if action == .stop {
                state.library.cancelMetadataLoad()
                for _ in 0..<100 {
                    if setupFinished { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                finishedBeforeRelease = setupFinished
                await state.sharedLibrary.coordinator?.stopMonitoring()
            } else if action == .switchLibrary {
                try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
                try Data("Other library original".utf8).write(to: other.appendingPathComponent("Other.mp3"))
                var switchFinished = false
                switchTask = Task { let result = await state.switchStorageLocation(to: .custom, customURL: other); switchFinished = true; return result }
                for _ in 0..<100 {
                    if switchFinished { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                finishedBeforeRelease = switchFinished
            }
            release.signal(); try await holding.value; try await setup.value
            if let switchTask { switched = await switchTask.value }
            let templatesReadyRevision = state.sharedLibrary.revision
            await state.sharedLibrary.close()
            if action == .complete {
                try expect(templatesReadyRevision > templatesBefore, "Completing shared template setup must notify existing B views without resetting their content identity")
                try expect(state.library.contentID(for: "B.mp3", fallbackRevision: 0) == bContentID, "Unrelated A catalog arrival must preserve B editor identity and its unsaved state")
                try expect(state.library.contentID(for: "B.mp3", fallbackRevision: 100) == bContentID, "Unrelated global refresh must preserve shared B editor identity")
                let b = try await seed.recording(at: "B.mp3")
                guard let generation = b.state.currentDocument(for: .transcript) else { throw Failure(description: "Missing B transcript generation") }
                _ = try await seed.edit(.init(base: b, changes: [.generationEdit(component: .transcript, generation: generation.id, key: "fixture-speaker", value: .text("Alice"))]))
                await state.library.refresh()
                try expect(state.library.contentID(for: "B.mp3", fallbackRevision: 0) != bContentID, "An actual B transcript change must invalidate B content")
                let otherRoot = LibraryState(store: RecordingStore(baseDirectory: folder.appendingPathComponent("different-root")), transcriptStore: TranscriptStore(baseDirectory: root))
                try expect(otherRoot.contentID(for: "B.mp3", fallbackRevision: 0) != bContentID, "Storage bindings must have distinct content identities")
            }
            try expect(emptyReady, "Independent empty folder identity arrives while unrelated authoritative metadata remains held")
            try expect(residentB?.reference != nil, "First launch must expose resident B with stable identity while unrelated A metadata remains held (deleted=\(deleted))")
            try expect(residentText == "Resident B.mp3", "B transcript must be usable while A metadata remains held")
            try expect(loadingVisible && badgesReady, "Waiting feedback and resident transcript/summary badges appear before A is available")
            try expect(!unknownAVisible, "Unknown lifecycle must not expose A's retained raw audio while metadata is pending")
            try expect(finishedBeforeRelease, "Stop/switch must complete without waiting for the held owner head")
            if action == .switchLibrary {
                try expect(switched && state.library.store.baseDirectory == other && state.library.recordings.map(\.filename) == ["Other.mp3"], "Late old setup must not overwrite the new library")
                try expect(!state.summarization.hasSummary.contains("B.mp3") && state.transcription.statuses["B.mp3"] == nil, "Old setup must not copy its badges into the new binding")
            } else {
                if action == .stop {
                    try expect(state.library.metadataLoadState == .stopped && !state.library.recordings.contains { $0.filename == "A.mp3" }, "Canceled load cannot publish A after release")
                    await state.retryLibraryLoad()
                    await state.sharedLibrary.close()
                    try expect(state.library.metadataLoadState == .idle && state.library.refreshError == nil, "Retry completes a fresh metadata request")
                }
                try expect(state.library.recordings.contains { $0.filename == "A.mp3" } == !deleted, "After metadata arrives/retries, respect A's accepted lifecycle")
            }
            try expect(try Data(contentsOf: root.appendingPathComponent("A.mp3")) == audioA, "Cold metadata must never mutate A original")
        }
        print("Actual cold metadata startup passed (\(action)): resident B/badges/loading independent; stop/retry/binding and retained-deletion safety.")
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
        guard let recording = state.library.recordings.first else { throw Failure(description: "Missing selected app recording") }
        await state.deleteLocalRecording(recording)
        let pending = try await coordinator.reviewRecordingOperation(id: original.state.id)
        let accepted = try await coordinator.read(.init(id: original.state.id, kind: .recording))
        try expect(accepted.state.lifecycle == .deleted, "Delete action must accept the logical deletion")
        try expect(pending?.purpose == .delete && pending?.hasActiveWork == true, "An active job must retain the original after logical deletion")
        try expect(state.errorMessage == nil, "An accepted pending deletion must not be reported as failed: " + (state.errorMessage ?? ""))
        try expect(state.statusMessage.contains("Pending Files"), "Explain where the user can finish pending cleanup")
        try expect(state.sharedLibrary.showsReview && state.sharedLibrary.reviewTab == .pendingFiles, "Open Pending Files for the accepted pending deletion")
        try expect(state.library.recordings.isEmpty, "The Delete action must hide the accepted deletion without another refresh")
        try expect(try Data(contentsOf: root.appendingPathComponent("Meeting.mp3")) == audio, "Visibility must never dispose or rewrite retained media")
        await state.sharedLibrary.close()
        let reopened = AppState(baseDirectory: root, sharedIdentity: identity, sharedWitnessDirectory: witnesses, sharedTrash: refuseTrash)
        try await reopened.setup()
        try expect(reopened.library.recordings.isEmpty, "Fresh launch must not rediscover a pending-deleted original as a new recording")
        await reopened.sharedLibrary.close()
        await coordinator.finishJob(token)
        print("Actual retained-deletion visibility passed: refresh and fresh launch hide pending original; audio unchanged.")
    }

    @MainActor static func deleteSelectionChecks(parent: URL) async throws {
        let root = parent.appendingPathComponent("library")
        let legacy = RecordingStore(baseDirectory: root)
        try await legacy.setup()
        var bytes = Data(repeating: 0, count: 417)
        bytes.replaceSubrange(0..<4, with: [0xFF, 0xFB, 0x90, 0x64])
        _ = try await legacy.importRecording(hdaData: bytes, entry: FileEntry(filename: "A.hda", size: UInt32(bytes.count)))
        let identity: @Sendable () async throws -> SharedLibraryWriterIdentity = {
            try await SharedLibraryWriterIdentityStore(file: parent.appendingPathComponent("identity.json"), installationAnchor: "delete-selection fixture").load()
        }
        let state = AppState(baseDirectory: root, sharedIdentity: identity, sharedWitnessDirectory: parent.appendingPathComponent("witnesses"),
            sharedTrash: { _ in throw Failure(description: "Protected deletion fixture must never attempt disposal") })
        try await state.setup()
        try expect(await state.enableSharedLibrary(), "Enable selected-deletion fixture")
        guard let coordinator = state.sharedLibrary.coordinator, let stale = state.library.recordings.first,
              let selected = stale.reference else { throw Failure(description: "Missing selected deletion identity") }
        await coordinator.stopMonitoring()
        _ = try await state.library.store.renameRecording(filename: "A.mp3", to: "Renamed")
        _ = try await state.library.store.importRecording(hdaData: bytes, entry: FileEntry(filename: "Unrelated.hda", size: UInt32(bytes.count)))
        _ = try await state.library.store.renameRecording(filename: "Unrelated.mp3", to: "A")
        let other = try await coordinator.reference(to: "A.mp3")
        let selectedJob = try await coordinator.pinJob(.init(id: selected.entityID, kind: .recording))
        let otherJob = try await coordinator.pinJob(.init(id: other.entityID, kind: .recording))
        await state.deleteLocalRecording(stale)
        let selectedAfter = try await coordinator.read(.init(id: selected.entityID, kind: .recording))
        let otherAfter = try await coordinator.read(.init(id: other.entityID, kind: .recording))
        try expect(selectedAfter.state.lifecycle == .deleted && otherAfter.state.lifecycle == .alive,
            "Delete must follow the selected identity after filename reuse; selected=\(selectedAfter.state.lifecycle), other=\(otherAfter.state.lifecycle)")
        try expect(state.errorMessage == nil, "Accepted selected deletion must be explained as pending, not failed")
        try expect(state.library.recordings.map(\.filename) == ["A.mp3"], "Only the unrelated replacement should remain visible")
        for name in ["A.mp3", "Renamed.mp3"] { try expect(try Data(contentsOf: root.appendingPathComponent(name)) == bytes, "Both vetoed fixture originals must be byte-identical") }
        let otherRoot = parent.appendingPathComponent("other-library")
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        let otherAudio = Data("Different library original".utf8)
        try otherAudio.write(to: otherRoot.appendingPathComponent("A.mp3"))
        try expect(await state.switchStorageLocation(to: .custom, customURL: otherRoot), "Switch selected-deletion library")
        state.errorMessage = nil
        await state.deleteLocalRecording(stale)
        try expect(state.errorMessage?.hasPrefix("Delete failed:") == true, "A stale shared selection must be refused in a legacy library")
        try expect(!state.sharedLibrary.showsReview, "A refused deletion must not open pending-success review")
        try expect(try Data(contentsOf: otherRoot.appendingPathComponent("A.mp3")) == otherAudio, "A stale selection must preserve the same filename in another library")
        try expect(await state.enableSharedLibrary(), "Enable second selected-deletion library")
        guard let otherCoordinator = state.sharedLibrary.coordinator else { throw Failure(description: "Missing second deletion binding") }
        await otherCoordinator.stopMonitoring()
        let otherReference = try await otherCoordinator.reference(to: "A.mp3")
        state.errorMessage = nil
        await state.deleteLocalRecording(stale)
        try expect(state.errorMessage?.hasPrefix("Delete failed:") == true, "A stale selection must also be refused in a different shared library")
        let preserved = try await otherCoordinator.read(.init(id: otherReference.entityID, kind: .recording))
        try expect(preserved.state.lifecycle == .alive, "The other library recording must remain alive")
        try expect(!state.sharedLibrary.showsReview, "A rejected cross-library deletion must not masquerade as pending success")
        try expect(try Data(contentsOf: otherRoot.appendingPathComponent("A.mp3")) == otherAudio, "Cross-library refusal must preserve the original")
        await state.sharedLibrary.close()
        await coordinator.finishJob(selectedJob); await coordinator.finishJob(otherJob)
        print("Actual selected deletion passed: stable identity survives rename/reused filename; legacy/shared library-switch refusal preserves unrelated originals.")
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

    @MainActor static func folderSelectionChecks(parent: URL) async throws {
        for action in ["delete", "rename"] {
            let directory = parent.appendingPathComponent(action), root = directory.appendingPathComponent("library")
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Folder"), withIntermediateDirectories: true)
            let original = Data("synthetic selected folder original".utf8)
            try original.write(to: root.appendingPathComponent("Folder/Clip.mp3"))
            let local = directory.appendingPathComponent("local"), identity = directory.appendingPathComponent("identity.json")
            let state = AppState(baseDirectory: root, sharedIdentity: {
                try await SharedLibraryWriterIdentityStore(file: identity, installationAnchor: "folder selection fixture").load()
            }, sharedWitnessDirectory: local, sharedTrash: { try FileManager.default.removeItem(at: $0) })
            try await state.setup(); try expect(await state.enableSharedLibrary(), "Enable folder selection fixture")
            guard let a = state.sharedLibrary.coordinator else { throw Failure(description: "Missing folder selection coordinator") }
            await a.stopMonitoring()
            let other = SharedLibraryCoordinator(root: root, writerID: a.writerID, witnessDirectory: local, trash: { try FileManager.default.removeItem(at: $0) })
            let moved = try await other.renameFolder(from: "Folder", to: "Moved")
            try expect(moved.result == .complete, "Actual original folder move completes")
            try await other.createSharedFolder(named: "Folder")
            let current = try await other.snapshots(kinds: [.folder])
            guard let replacement = current.first(where: { $0.state.value(for: "name") == .text("Folder") }) else { throw Failure(description: "Missing replacement folder") }
            try expect(state.library.folders == ["Folder"], "Fixture retains its actual displayed folder catalog before sync refresh")
            if action == "delete" { await state.deleteFolder(named: "Folder") }
            else { await state.renameFolder(from: "Folder", to: "Unexpected") }
            let after = try await other.read(.init(id: replacement.state.id, kind: .folder))
            try expect(after.state.lifecycle == .alive && after.state.value(for: "name") == .text("Folder") && after.state.value(for: "deletionRequest") == nil,
                "Stale displayed \(action) must not accept an operation on the replacement folder")
            try expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Folder").path), "Replacement folder remains at its selected name")
            try expect(try Data(contentsOf: root.appendingPathComponent("Moved/Clip.mp3")) == original, "Original moved folder bytes stay unchanged")
            try expect(state.errorMessage != nil, "Stale displayed folder action needs a reload error")
            await state.sharedLibrary.close()
        }
        print("Actual stable folder selection passed: stale displayed Rename/Delete cannot retarget a reused name.")
    }

    @MainActor static func capturedFolderSelectionChecks(parent: URL) async throws {
        for scenario in ["editor", "same-library-copy", "legacy-root"] {
            let directory = parent.appendingPathComponent(scenario), root = directory.appendingPathComponent("library")
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Folder"), withIntermediateDirectories: true)
            let original = Data("synthetic captured folder".utf8)
            try original.write(to: root.appendingPathComponent("Folder/Clip.mp3"))
            let local = directory.appendingPathComponent("local"), identity = directory.appendingPathComponent("identity.json")
            let state = AppState(baseDirectory: root, sharedIdentity: {
                try await SharedLibraryWriterIdentityStore(file: identity, installationAnchor: "captured folder fixture").load()
            }, sharedWitnessDirectory: local, sharedTrash: { try FileManager.default.removeItem(at: $0) })
            try await state.setup(); try expect(await state.enableSharedLibrary(), "Enable captured folder fixture")
            guard let a = state.sharedLibrary.coordinator else { throw Failure(description: "Missing captured folder coordinator") }
            await a.stopMonitoring()
            let selection = state.library.folderSelection(named: "Folder")
            try expect(selection.reference != nil, "Displayed folder has an accepted identity")
            if scenario == "editor" {
                let other = SharedLibraryCoordinator(root: root, writerID: a.writerID, witnessDirectory: local)
                _ = try await other.renameFolder(from: "Folder", to: "Moved")
                try await other.createSharedFolder(named: "Folder")
                await state.refreshAll()
                try expect(state.library.folderSelection(named: "Folder").reference != selection.reference, "Fresh catalog identifies replacement")
                await state.renameFolder(selection: selection, to: "Unexpected")
                try expect(state.errorMessage != nil && FileManager.default.fileExists(atPath: root.appendingPathComponent("Folder").path), "Editor retains original selection across refresh")
                try expect(try Data(contentsOf: root.appendingPathComponent("Moved/Clip.mp3")) == original, "Editor cannot alter moved original")
            } else {
                let next = directory.appendingPathComponent("next")
                if scenario == "same-library-copy" { try FileManager.default.copyItem(at: root, to: next) }
                else {
                    try FileManager.default.createDirectory(at: next.appendingPathComponent("Folder"), withIntermediateDirectories: true)
                    try original.write(to: next.appendingPathComponent("Folder/Clip.mp3"))
                }
                try expect(await state.switchStorageLocation(to: .custom, customURL: next), "Switch actual app binding before queued action")
                let current = state.library.folderSelection(named: "Folder")
                try expect(current.libraryBinding != selection.libraryBinding, "New LibraryState has a distinct binding")
                if scenario == "same-library-copy" { try expect(current.reference == selection.reference, "Same library UUID still needs root-instance protection") }
                await state.deleteFolder(selection: selection)
                try expect(state.errorMessage != nil && FileManager.default.fileExists(atPath: next.appendingPathComponent("Folder").path), "Queued Delete cannot target new root")
                await state.renameFolder(selection: selection, to: "Unexpected")
                try expect(state.errorMessage != nil && FileManager.default.fileExists(atPath: next.appendingPathComponent("Folder").path), "Queued Rename cannot target new root")
                try expect(try Data(contentsOf: next.appendingPathComponent("Folder/Clip.mp3")) == original && Data(contentsOf: root.appendingPathComponent("Folder/Clip.mp3")) == original, "Both fixture copies preserved")
            }
            await state.sharedLibrary.close()
        }
        print("Actual captured folder selection passed: refreshed editor and different-root/same-library-copy actions refuse.")
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
        try expect(Set(state.library.recordings.map(\.filename)) == ["Renamed/A.mp3", "Renamed/Nested/B.mp3"], "Actual app must refresh all renamed descendant paths; paths=\(state.library.recordings.map(\.filename)), error=\(state.library.refreshError ?? "none"), loading=\(state.library.isLoadingMetadata)")
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
