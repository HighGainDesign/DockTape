// © 2026 High Gain Design. All rights reserved.
import AppKit
import HiDockKit

@main struct DockTapeSharedReviewTests {
    actor CommitCount {
        private var count = 0
        func next() -> Int { count += 1; return count }
    }
    actor SavePause {
        private(set) var entered = false
        private var continuation: CheckedContinuation<Void, Never>?
        func pauseOnce() async {
            guard !entered else { return }
            entered = true
            await withCheckedContinuation { continuation = $0 }
        }
        func release() { continuation?.resume(); continuation = nil }
    }
    actor PauseSecondRead {
        var count = 0
        private(set) var entered = false
        var continuation: CheckedContinuation<Void, Never>?
        func visit() async {
            count += 1
            if count == 2 { entered = true; await withCheckedContinuation { continuation = $0 } }
        }
        func release() { continuation?.resume(); continuation = nil }
    }
    struct Failure: Error { let message: String }
    static func expect(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message: message) } }
    static func deliver(_ source: URL, to destination: URL, writer: UUID) throws {
        let tree = source.appendingPathComponent(".docktape").resolvingSymlinksInPath()
        guard let files = FileManager.default.enumerator(at: tree, includingPropertiesForKeys: [.isDirectoryKey]) else { throw Failure(message: "No metadata") }
        for case let file as URL in files where file.pathExtension == "json" {
            let bytes = try Data(contentsOf: file)
            let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] ?? [:]
            let payload = object["payload"] as? [String: Any]
            let owner = (object["writerID"] as? String) ?? (payload?["writer"] as? String) ?? (object["founder"] as? String)
            guard owner.flatMap(UUID.init(uuidString:)) == writer else { continue }
            let relative = String(file.resolvingSymlinksInPath().path.dropFirst(tree.path.count + 1))
            let target = destination.appendingPathComponent(".docktape/" + relative)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: target, options: .atomic)
        }
    }
    @MainActor private static var qaWindow: MainWindowController?
    @MainActor static func main() {
        _ = NSApplication.shared
        let ui = CommandLine.arguments.contains("--ui")
        Task { @MainActor in
            do {
                try await run()
                if !ui { exit(0) }
            } catch {
                fputs("Review QA failed: \(error)\n", stderr)
                exit(1)
            }
        }
        NSApp.run()
    }
    @MainActor static func externalReviewChecks(parent: URL) async throws {
        let root = parent.appendingPathComponent("external-files")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["Changed.mp3", "Unrelated.mp3"] {
            try Data("synthetic fixture".utf8).write(to: root.appendingPathComponent(name))
            try await TranscriptStore(baseDirectory: root).save(Transcript(recordingFilename: name, transcriptionModel: "fixture", hasSpeakerLabels: false,
                segments: [.init(startTime: 0, endTime: 1, text: "Current " + name)]), mp3Filename: name)
        }
        UserDefaults.standard.setVolatileDomain(["storageMode": "local"], forName: UserDefaults.argumentDomain)
        let identityFile = parent.appendingPathComponent("external-identity.json")
        let state = AppState(baseDirectory: root, sharedIdentity: {
            try await SharedLibraryWriterIdentityStore(file: identityFile, installationAnchor: "external fixture").load()
        }, sharedWitnessDirectory: parent.appendingPathComponent("external-witnesses"))
        try await state.setup()
        try expect(await state.enableSharedLibrary(), "Enable actual AppState external-file fixture")
        await state.refreshAll() // Finish initial shared-state publication before capturing unrelated bytes.
        guard let coordinator = state.sharedLibrary.coordinator else { throw Failure(message: "Missing binding") }
        let model = state.sharedLibrary.externalReview
        await model.refresh(using: coordinator)
        try expect(model.items.isEmpty && model.message == nil, "Own files are not external changes")
        let unrelated = root.appendingPathComponent("Unrelated.transcript.json")
        let unrelatedBytes = try Data(contentsOf: unrelated)
        let file = root.appendingPathComponent("Changed.transcript.json")
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        var segments = object["segments"] as! [[String: Any]]
        segments[0]["text"] = "Changed by another computer"
        object["segments"] = segments
        try JSONSerialization.data(withJSONObject: object, options: .sortedKeys).write(to: file, options: .atomic)
        await state.refreshAll()
        // A monitored refresh can supersede the awaited request. Observe the
        // current request's result without issuing another refresh or write.
        let feedbackDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while state.sharedLibrary.message?.contains("External Files") != true,
              ContinuousClock.now < feedbackDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try expect(state.sharedLibrary.message?.contains("External Files") == true,
            "Actual app explains where recovery lives; message=" + (state.sharedLibrary.message ?? "<nil>"))
        await model.refresh(using: coordinator)
        try expect(model.items.count == 1 && model.items[0].review?.changedText?.contains("another computer") == true, "Comparison shows actual external content")
        let stale = model.items[0]
        try Data("damaged sync content".utf8).write(to: file, options: .atomic)
        try expect(!(await model.apply(stale, useChangedFile: true, using: coordinator)), "Unseen bytes refuse old decision")
        try expect(model.message?.contains("changed during review") == true, "Stale decision gives actionable message")
        await model.refresh(using: coordinator)
        try expect(model.items.count == 1 && model.items[0].review?.changedText == nil, "Damaged file offers restoration only")
        try expect(await model.apply(model.items[0], useChangedFile: false, using: coordinator), "Restore current via actual app review")
        await state.refreshAll()
        let restored = try await state.transcription.transcriptStore.loadTranscript(for: "Changed.mp3")
        try expect(restored?.plainText().contains("Current Changed.mp3") == true, "Actual app cache reads restored current content")
        try expect(try Data(contentsOf: unrelated) == unrelatedBytes, "Unrelated resident recording is byte-identical")
        object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        segments = object["segments"] as! [[String: Any]]; segments[0]["text"] = "Accepted external transcript"; object["segments"] = segments
        try JSONSerialization.data(withJSONObject: object, options: .sortedKeys).write(to: file, options: .atomic)
        await model.refresh(using: coordinator)
        try expect(await model.apply(model.items[0], useChangedFile: true, using: coordinator), "Use changed content via app review")
        await state.refreshAll()
        let adopted = try await state.transcription.transcriptStore.loadTranscript(for: "Changed.mp3")
        try expect(adopted?.plainText().contains("Accepted external transcript") == true, "Actual app invalidates cached transcript after choice")
        // Suspend one actual publication read while another external row is ready.
        for name in ["Changed", "Unrelated"] {
            let file = root.appendingPathComponent(name + ".transcript.json")
            var body = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
            var rows = body["segments"] as! [[String: Any]]
            rows[0]["text"] = "Independent external " + name; body["segments"] = rows
            try JSONSerialization.data(withJSONObject: body, options: .sortedKeys).write(to: file, options: .atomic)
        }
        let pause = PauseSecondRead()
        let delayed = SharedLibraryCoordinator(root: root, writerID: coordinator.writerID,
            witnessDirectory: parent.appendingPathComponent("external-witnesses"), afterPublishedLibraryRead: { await pause.visit() })
        let independent = ExternalSidecarReviewState()
        let scan = Task { @MainActor in await independent.refresh(using: delayed) }
        for _ in 0..<300 {
            if await pause.entered, !independent.items.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try expect(await pause.entered && independent.isLoading && independent.items.count == 1, "Resident row must appear while unrelated read is pending")
        let resident = independent.items[0]
        let applied = await independent.apply(resident, useChangedFile: true, using: delayed)
        await pause.release(); await scan.value
        try expect(applied, "Resident external file remains actionable while unrelated read waits")
        try expect(!independent.items.contains(where: { $0.id == resident.id }), "Late canceled scan cannot restore old consent")
        independent.clear()
        model.clear()
        try expect(model.items.isEmpty && model.message == nil, "Changing libraries clears external consent")
        await state.sharedLibrary.close()
        try await independentPublicationChecks(parent: parent, writer: coordinator.writerID)
        print("Actual external-file AppState checks passed: changed/corrupt/stale file, comparison, restoration, adoption, cache refresh and unrelated-file preservation.")
    }
    @MainActor static func independentPublicationChecks(parent: URL, writer: UUID) async throws {
        let root = parent.appendingPathComponent("independent-publication")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["A.mp3", "B.mp3"] {
            try Data("synthetic publication audio".utf8).write(to: root.appendingPathComponent(name))
            try await TranscriptStore(baseDirectory: root).save(Transcript(recordingFilename: name, transcriptionModel: "fixture", hasSpeakerLabels: false,
                segments: [.init(startTime: 0, endTime: 1, text: "Current " + name)]), mp3Filename: name)
        }
        try await SummaryStore(baseDirectory: root).save(Summary(recordingFilename: "B.mp3", model: "fixture", provider: "fixture", templateUsed: "fixture",
            sections: [.init(heading: "Summary", content: "Unchanged B summary")]), mp3Filename: "B.mp3")
        let coordinator = SharedLibraryCoordinator(root: root, writerID: writer, witnessDirectory: parent.appendingPathComponent("publication-witnesses"))
        _ = try await coordinator.enable(); _ = try await coordinator.projectOutputs()
        let file = root.appendingPathComponent("B.transcript.json")
        for (index, heldPath) in ["A.transcript.json", "B.summary.json"].enumerated() {
            var body = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
            var segments = body["segments"] as! [[String: Any]]
            let changedText = "Independent recovery trial " + String(index)
            segments[0]["text"] = changedText; body["segments"] = segments
            try JSONSerialization.data(withJSONObject: body).write(to: file, options: .atomic)
            let model = ExternalSidecarReviewState()
            await model.refresh(using: coordinator)
            guard let row = model.items.first(where: { $0.review?.filename == "B.mp3" }) else { throw Failure(message: "Missing resident recovery row") }
            let heldFile = root.appendingPathComponent(heldPath)
            let heldBytes = try Data(contentsOf: heldFile)
            let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            let holding = Task {
                try await CoordinatedFileAccess().withWrite(at: heldFile) { _ in
                    started.signal()
                    guard release.wait(timeout: .now() + 8) == .success else { throw Failure(message: "Fixture coordination hold timed out") }
                }
            }
            let acquired = await withCheckedContinuation { continuation in
                DispatchQueue.global().async { continuation.resume(returning: started.wait(timeout: .now() + 2) == .success) }
            }
            guard acquired else { release.signal(); _ = try? await holding.value; throw Failure(message: "Fixture did not acquire its one-file lease") }
            var completed = false
            let applying = Task { @MainActor in
                let result = await model.apply(row, useChangedFile: true, using: coordinator)
                completed = true
                return result
            }
            for _ in 0..<150 {
                if completed { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let independent = completed
            release.signal(); try await holding.value
            let applied = await applying.value
            try expect(independent, "Resident transcript recovery must finish while " + heldPath + " remains held")
            try expect(applied && model.message == "Changed file accepted.", "Recovery must publish its selected output successfully")
            let output = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
            try expect((output["segments"] as? [[String: Any]])?.first?["text"] as? String == changedText, "Selected JSON reflects accepted content")
            try expect(try String(contentsOf: root.appendingPathComponent("B.transcript.md"), encoding: .utf8).contains(changedText), "Selected Markdown is updated")
            try expect(try String(contentsOf: root.appendingPathComponent("B.txt"), encoding: .utf8).contains(changedText), "Selected TXT is updated")
            try expect(try Data(contentsOf: heldFile) == heldBytes, "Held unrelated output remains byte-identical")
            model.clear()
        }
        let originalA = try Data(contentsOf: root.appendingPathComponent("A.mp3"))
        let cancelled = SharedLibraryCoordinator(root: root, writerID: writer,
            witnessDirectory: parent.appendingPathComponent("publication-witnesses"),
            afterCommit: { withUnsafeCurrentTask { $0?.cancel() } })
        let moving = Task { try await cancelled.relocateRecording(filename: "A.mp3", title: "Pending A") }
        do { _ = try await moving.value; throw Failure(message: "Fixture must leave A's accepted rename pending") }
        catch is CancellationError {}
        let changedText = "Resident B while A rename is pending"
        var body = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        var segments = body["segments"] as! [[String: Any]]; segments[0]["text"] = changedText; body["segments"] = segments
        try JSONSerialization.data(withJSONObject: body).write(to: file)
        let pendingModel = ExternalSidecarReviewState()
        await pendingModel.refresh(using: coordinator)
        guard let pendingRow = pendingModel.items.first(where: { $0.review?.filename == "B.mp3" }) else { throw Failure(message: "Missing B recovery during pending A rename") }
        try expect(await pendingModel.apply(pendingRow, useChangedFile: true, using: coordinator), "B recovery must remain actionable with pending A rename")
        try expect(pendingModel.message == "Changed file accepted.", "B recovery must publish, not leave an unfinished-operation export error")
        for suffix in [".transcript.md", ".txt"] {
            try expect(try String(contentsOf: root.appendingPathComponent("B" + suffix), encoding: .utf8).contains(changedText), "B readable export updated during pending A rename")
        }
        try expect(try Data(contentsOf: root.appendingPathComponent("A.mp3")) == originalA, "Pending A original must remain unchanged")
        try expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Pending A.mp3").path), "B recovery must not materialize A's pending rename")
        pendingModel.clear()
        print("Actual independent publication passed: resident transcript JSON/Markdown/TXT recovery finishes with unrelated recording/same-recording summary held and accepted A rename pending.")
    }
    @MainActor static func folderRequestConflictChecks(parent: URL) async throws {
        let left = parent.appendingPathComponent("left"), right = parent.appendingPathComponent("right")
        try FileManager.default.createDirectory(at: left.appendingPathComponent("Folder"), withIntermediateDirectories: true)
        let audio = Data("folder request synthetic original".utf8)
        try audio.write(to: left.appendingPathComponent("Folder/A.mp3"))
        let aw = UUID(), bw = UUID(), alocal = parent.appendingPathComponent("a-local"), blocal = parent.appendingPathComponent("b-local")
        let a = SharedLibraryCoordinator(root: left, writerID: aw, witnessDirectory: alocal, trash: { _ in throw Failure(message: "Pinned fixture must retain originals") })
        _ = try await a.enable(); _ = try await a.projectOutputs()
        try FileManager.default.copyItem(at: left, to: right)
        let b = SharedLibraryCoordinator(root: right, writerID: bw, witnessDirectory: blocal, trash: { _ in throw Failure(message: "Offline fixture must retain originals") })
        try await b.requestEnrollment(requestID: UUID(), label: "Folder peer")
        for _ in 0..<3 {
            try deliver(right, to: left, writer: bw); try await a.refresh()
            try deliver(left, to: right, writer: aw); try await b.refresh()
        }
        // Each request is generated by the actual folder command, interrupted
        // immediately after its durable request and before child deletion.
        let stoppedA = SharedLibraryCoordinator(root: left, writerID: aw, witnessDirectory: alocal,
            afterCommit: { withUnsafeCurrentTask { $0?.cancel() } })
        let first = Task { try await stoppedA.deleteFolder(named: "Folder") }
        do { _ = try await first.value; throw Failure(message: "Expected request interruption A") } catch is CancellationError { }
        let store = RecordingStore(baseDirectory: right, shared: SharedRecordingMetadataAdapter(coordinator: b)); try await store.setup()
        var bytes = Data(repeating: 0, count: 417); bytes.replaceSubrange(0..<4, with: [0xFF, 0xFB, 0x90, 0x64])
        _ = try await store.importRecording(hdaData: bytes, entry: FileEntry(filename: "B.hda", size: UInt32(bytes.count)))
        _ = try await store.moveRecording(filename: "B.mp3", toFolder: "Folder")
        let stoppedB = SharedLibraryCoordinator(root: right, writerID: bw, witnessDirectory: blocal,
            afterCommit: { withUnsafeCurrentTask { $0?.cancel() } })
        let second = Task { try await stoppedB.deleteFolder(named: "Folder") }
        do { _ = try await second.value; throw Failure(message: "Expected request interruption B") } catch is CancellationError { }
        try deliver(right, to: left, writer: bw)
        try Data(contentsOf: right.appendingPathComponent("library.json")).write(to: left.appendingPathComponent("library.json"), options: .atomic)
        try Data(contentsOf: right.appendingPathComponent("Folder/B.mp3")).write(to: left.appendingPathComponent("Folder/B.mp3"))
        try await a.refresh()
        let model = SharedLibraryReviewState(); await model.refresh(using: a)
        guard let item = model.items.first(where: { $0.snapshot.state.kind == .folder }),
              let field = item.fields.first(where: { $0.id == "deletionRequest" }) else { throw Failure(message: "Missing competing folder request") }
        try expect(field.choices.count == 2, "Competing deletion requests need explicit choices instead of an unresolvable recovery placeholder")
        try expect(field.choices.contains { $0.detail.contains("From: This Mac") } && field.choices.contains { $0.detail.contains("From: Folder peer") }, "Folder request scopes identify their source Macs")
        try expect(field.choices.allSatisfy { $0.detail.contains("Folder/A.mp3") }, "Every request previews its actual original child")
        guard let selected = field.choices.first(where: { $0.detail.contains("Folder/B.mp3") }) else { throw Failure(message: "Newer request must preview its additional child") }
        try expect(field.choices.filter { $0.detail.contains("Folder/B.mp3") }.count == 1, "Request previews distinguish the offline child scopes")
        var jobs: [SharedLibraryJobToken] = []
        for name in ["Folder/A.mp3", "Folder/B.mp3"] {
            let reference = try await a.reference(to: name)
            jobs.append(try await a.pinJob(.init(id: reference.entityID, kind: .recording)))
        }
        _ = try await a.edit(.init(base: item.snapshot, changes: [.assign(field: "description", value: .text("arrived during review"))]))
        try expect(!(await model.apply(item: item, selections: [field.id: selected.id], using: a)), "Unseen folder changes refuse stale request consent")
        try expect(model.message?.contains("changed during review") == true, "Stale request explains reloading")
        await model.refresh(using: a)
        guard let current = model.items.first(where: { $0.id == item.id }),
              let currentField = current.fields.first(where: { $0.id == "deletionRequest" }),
              let currentChoice = currentField.choices.first(where: { $0.value == selected.value }) else { throw Failure(message: "Reloaded request choice disappeared") }
        try expect(await model.apply(item: current, selections: [currentField.id: currentChoice.id], using: a), "Actual model saves only the newly reviewed selected request")
        let accepted = try await a.read(.init(id: item.id, kind: .folder))
        try expect(!accepted.state.conflicts.contains { $0.field == "deletionRequest" }, "Request conflict is causally resolved")
        try expect(accepted.state.value(for: "deletionRequest") == selected.value, "Only the displayed chosen request is retained")
        try expect(model.message?.contains("Pending Folders") == true, "Explain retained cleanup and where to continue")
        for name in ["Folder/A.mp3", "Folder/B.mp3"] { try expect(FileManager.default.fileExists(atPath: left.appendingPathComponent(name).path), "Pinned original remains") }
        let pending = FolderFileReviewState()
        await pending.refresh(using: a)
        try expect(pending.items.contains { $0.id == item.id && $0.isDeletionRequest && $0.hasActiveWork }, "Chosen request is actionable through the existing Pending Folders model, with active work protected")
        for job in jobs { await a.finishJob(job) }
        await pending.refresh(using: a)
        guard let ready = pending.items.first(where: { $0.id == item.id }), ready.canResume else { throw Failure(message: "Fresh Pending Folders must offer the explicit continuation") }
        try expect(await pending.perform(.resume, review: ready, using: a), "Reviewed Resume continues the selected normal deletion request")
        try expect(pending.message?.contains("Waiting for approval") == true, "Continuation must reach normal cohort approval, not an unusable changed plan: " + (pending.message ?? "<nil>"))
        try expect(FileManager.default.fileExists(atPath: left.appendingPathComponent("Folder/A.mp3").path)
            && FileManager.default.fileExists(atPath: left.appendingPathComponent("Folder/B.mp3").path), "Offline peer still prevents physical deletion after explicit continuation")
        print("Actual folder-request conflict passed: offline child scopes readable, exact selected request saved, normal pending cleanup retains originals.")
    }

    @MainActor static func pendingFolderChecks(parent: URL, interruptBeforeOwnerApproval: Bool = false) async throws {
        let left = parent.appendingPathComponent("left"), right = parent.appendingPathComponent("right")
        try FileManager.default.createDirectory(at: left.appendingPathComponent("Empty"), withIntermediateDirectories: true)
        UserDefaults.standard.setVolatileDomain(["storageMode": "local"], forName: UserDefaults.argumentDomain)
        let identity = parent.appendingPathComponent("identity.json")
        let state = AppState(baseDirectory: left, sharedIdentity: {
            try await SharedLibraryWriterIdentityStore(file: identity, installationAnchor: "folder fixture").load()
        }, sharedWitnessDirectory: parent.appendingPathComponent("a-local"), sharedTrash: { try FileManager.default.removeItem(at: $0) })
        try await state.setup()
        try expect(await state.enableSharedLibrary(), "Enable actual folder fixture")
        guard let a = state.sharedLibrary.coordinator else { throw Failure(message: "Missing folder coordinator") }
        try FileManager.default.copyItem(at: left, to: right)
        let b = SharedLibraryCoordinator(root: right, writerID: UUID(), witnessDirectory: parent.appendingPathComponent("b-local"), trash: { try FileManager.default.removeItem(at: $0) })
        try await b.requestEnrollment(requestID: UUID(), label: "Folder peer")
        for _ in 0..<3 {
            try deliver(right, to: left, writer: b.writerID); try await a.refresh()
            try deliver(left, to: right, writer: a.writerID); try await b.refresh()
        }
        await state.refreshAll()
        if interruptBeforeOwnerApproval {
            await state.sharedLibrary.close()
            let count = CommitCount()
            let interrupted = SharedLibraryCoordinator(root: left, writerID: a.writerID,
                witnessDirectory: parent.appendingPathComponent("a-local"),
                afterCommit: { if await count.next() == 2 { withUnsafeCurrentTask { $0?.cancel() } } },
                trash: { try FileManager.default.removeItem(at: $0) })
            let action = Task { try await interrupted.deleteFolder(named: "Empty") }
            do { _ = try await action.value; throw Failure(message: "Expected interruption after final deletion acceptance") }
            catch is CancellationError {}
        } else {
            await state.deleteFolder(named: "Empty")
            try expect(state.errorMessage == nil, "Accepted pending folder deletion must not be reported as failure")
            try expect(state.sharedLibrary.showsReview && state.sharedLibrary.reviewTab == .pendingFolders, "Accepted pending folder action opens its review tab")
        }
        let pending = await state.library.store.sharedFolderOperation
        let folderViews = try await a.snapshots(kinds: [.folder])
        try expect(folderViews.contains { $0.state.value(for: "name") == .text("Empty") && $0.state.value(for: "deletionRequest") != nil }, "Actual folder deletion must have a durable request even when a refresh interrupts follow-through; outcome=\(String(describing: pending?.result)), error=\(String(describing: state.errorMessage))")
        try expect(FileManager.default.fileExists(atPath: left.appendingPathComponent("Empty").path), "Pending folder original remains until approval")
        await state.sharedLibrary.close()
        // Use the actual review model after shutting down the AppState watcher,
        // so each approval below is tied to one displayed, unchanged snapshot.
        let ownerModel = FolderFileReviewState(), peerModel = FolderFileReviewState()
        await ownerModel.refresh(using: a)
        guard let first = ownerModel.items.first else { throw Failure(message: "Accepted folder request needs a visible row") }
        if interruptBeforeOwnerApproval {
            try expect(first.canAcknowledge && !first.canResume, "An interrupted owner approval must stay explicit before destruction")
        }
        if first.canResume { try expect(await ownerModel.perform(.resume, review: first, using: a), "Continue accepted folder request through the native model") }
        // Deliver the matching canonical library as well as its latest registry.
        // Registry-only arrival is deliberately retained in the diagnostic log.
        try deliver(left, to: right, writer: a.writerID)
        try Data(contentsOf: left.appendingPathComponent("library.json")).write(to: right.appendingPathComponent("library.json"), options: .atomic)
        try await b.refresh()
        do { _ = try await b.reviewFolderOperation(id: first.id) }
        catch { throw Failure(message: "Peer direct folder inspection failed: \(error)") }
        await peerModel.refresh(using: b)
        guard let peer = peerModel.items.first, peer.canAcknowledge else { throw Failure(message: "Peer needs a native folder deletion approval; owner=\(String(describing: ownerModel.message)), ownerRows=\(ownerModel.items.map { "\($0.name):\($0.purpose):ack\($0.canAcknowledge):resume\($0.canResume):replan\($0.needsReplanning)" }), peerRows=\(peerModel.items.map { "\($0.name):\($0.purpose):ack\($0.canAcknowledge):resume\($0.canResume):replan\($0.needsReplanning)" }), error=\(String(describing: peerModel.message))") }
        try expect(await peerModel.perform(.acknowledge, review: peer, using: b), "Native peer approval succeeds")
        try expect(FileManager.default.fileExists(atPath: right.appendingPathComponent("Empty").path), "Approval alone does not remove the peer folder")
        try deliver(right, to: left, writer: b.writerID)
        await ownerModel.refresh(using: a)
        if interruptBeforeOwnerApproval {
            try expect(ownerModel.items.first?.canAcknowledge == true && ownerModel.items.first?.canResume == false,
                       "Peer approval cannot imply the interrupted owner's consent")
        }
        if let unapproved = ownerModel.items.first, unapproved.canAcknowledge {
            let entity = SharedEntityIdentity(id: first.id, kind: .folder)
            let before = try await a.read(entity)
            try expect(unapproved.id == first.id && FileManager.default.fileExists(atPath: left.appendingPathComponent("Empty").path),
                       "Unapproved deletion keeps the original folder")
            try expect(await ownerModel.perform(.acknowledge, review: unapproved, using: a), "Explicit native owner approval succeeds")
            let after = try await a.read(entity)
            try expect(try SharedLibraryOperation.revision(for: before.state) == SharedLibraryOperation.revision(for: after.state),
                       "Approval changes no semantic folder state")
            try expect(FileManager.default.fileExists(atPath: left.appendingPathComponent("Empty").path), "Approval alone cannot remove the folder")
            try expect(ownerModel.items.first?.id == first.id && ownerModel.items.first?.canAcknowledge == false
                       && ownerModel.items.first?.waitingForMacs.contains("This Mac") == false,
                       "Fresh owner review records the explicit approval")
        }
        guard let current = ownerModel.items.first, current.canResume else { throw Failure(message: "Owner needs native Resume after cohort approval; rows=\(ownerModel.items.map { "\($0.name):ack\($0.canAcknowledge):resume\($0.canResume):replan\($0.needsReplanning):waiting\($0.waitingForMacs)" }), error=\(String(describing: ownerModel.message))") }
        try expect(await ownerModel.perform(.resume, review: current, using: a), "Native owner Resume completes approved empty-folder deletion")
        try expect(ownerModel.items.isEmpty && !FileManager.default.fileExists(atPath: left.appendingPathComponent("Empty").path), "Owner row clears only after actual removal")
        try deliver(left, to: right, writer: a.writerID)
        try Data(contentsOf: left.appendingPathComponent("library.json")).write(to: right.appendingPathComponent("library.json"), options: .atomic)
        await peerModel.refresh(using: b)
        try expect(peerModel.items.count == 1, "Metadata-first arrival cannot hide a retained peer folder")
        try FileManager.default.removeItem(at: right.appendingPathComponent("Empty"))
        await peerModel.refresh(using: b)
        try expect(peerModel.items.isEmpty, "Native peer row clears after acknowledged provider removal")
        ownerModel.clear(); peerModel.clear()
        print("Actual pending folder review passed: accepted feedback, peer approval, owner Resume and metadata-first provider removal.")
    }

    @MainActor static func rejectedFolderRenameChecks(parent: URL) async throws {
        let root = parent.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Folder"), withIntermediateDirectories: true)
        let audio = Data("synthetic folder rename original".utf8)
        try audio.write(to: root.appendingPathComponent("Folder/Clip.mp3"))
        UserDefaults.standard.setVolatileDomain(["storageMode": "local"], forName: UserDefaults.argumentDomain)
        let identity = parent.appendingPathComponent("identity.json")
        let state = AppState(baseDirectory: root, sharedIdentity: {
            try await SharedLibraryWriterIdentityStore(file: identity, installationAnchor: "folder rename fixture").load()
        }, sharedWitnessDirectory: parent.appendingPathComponent("local"))
        try await state.setup(); try expect(await state.enableSharedLibrary(), "Enable rejected folder rename fixture")
        guard let a = state.sharedLibrary.coordinator else { throw Failure(message: "Missing folder rename coordinator") }
        do {
            _ = try await a.renameFolder(from: "Folder", to: "Accepted", afterMutation: { _ in throw Failure(message: "accepted rename interrupted") })
            throw Failure(message: "Expected accepted rename interruption")
        } catch let failure as Failure { try expect(failure.message == "accepted rename interrupted", "Expected physical interruption") }
        await state.renameFolder(from: "Folder", to: "Rejected")
        try expect(state.errorMessage != nil, "Rejected new destination cannot be described as the older accepted pending rename")
        let views = try await a.snapshots(kinds: [.folder])
        try expect(views.contains { $0.state.value(for: "name") == .text("Accepted") }, "Rejected rename preserves the previously accepted target")
        try expect(try Data(contentsOf: root.appendingPathComponent("Accepted/Clip.mp3")) == audio && !FileManager.default.fileExists(atPath: root.appendingPathComponent("Rejected").path), "Rejected rename preserves the original at its accepted location")
        await state.sharedLibrary.close()
        print("Actual rejected folder rename passed: an older pending plan cannot imply acceptance of a different destination.")
    }

    @MainActor static func folderFeedbackChecks(parent: URL) async throws {
        let left = parent.appendingPathComponent("left"), right = parent.appendingPathComponent("right")
        try FileManager.default.createDirectory(at: left.appendingPathComponent("Empty"), withIntermediateDirectories: true)
        let writer = UUID(), local = parent.appendingPathComponent("local")
        let seed = SharedLibraryCoordinator(root: left, writerID: writer, witnessDirectory: local,
            afterCommit: { withUnsafeCurrentTask { $0?.cancel() } }, trash: { try FileManager.default.removeItem(at: $0) })
        _ = try await seed.enable()
        let initial = Task { try await seed.deleteFolder(named: "Empty") }
        do { _ = try await initial.value; throw Failure(message: "Expected interruption after folder request") } catch is CancellationError {}
        let model = FolderFileReviewState(), pause = SavePause()
        let a = SharedLibraryCoordinator(root: left, writerID: writer, witnessDirectory: local,
            afterPublishedLibraryRead: {
                if await MainActor.run(body: { model.isWorking && model.isLoading }) { await pause.pauseOnce() }
            }, trash: { try FileManager.default.removeItem(at: $0) })
        await model.refresh(using: a)
        guard let row = model.items.first, row.canResume else { throw Failure(message: "Expected resumable interrupted folder request") }
        let action = Task { await model.perform(.resume, review: row, using: a) }
        for _ in 0..<250 {
            if await pause.entered { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard await pause.entered else { action.cancel(); await pause.release(); _ = await action.value; throw Failure(message: "Folder feedback fixture did not reach post-action refresh") }
        try expect(!FileManager.default.fileExists(atPath: left.appendingPathComponent("Empty").path), "The action completed in its original library before feedback was held")
        model.clear()
        try FileManager.default.createDirectory(at: right.appendingPathComponent("Other"), withIntermediateDirectories: true)
        let b = SharedLibraryCoordinator(root: right, writerID: UUID(), witnessDirectory: parent.appendingPathComponent("other-local"))
        _ = try await b.enable()
        await model.refresh(using: b)
        await pause.release(); _ = await action.value
        try expect(model.items.isEmpty && model.message == nil && !model.isWorking && !model.isLoading, "Old folder action feedback cannot overwrite the new library after its awaited refresh")
        try expect(FileManager.default.fileExists(atPath: right.appendingPathComponent("Other").path), "Library switching cannot touch the new library's folder")
        model.clear()
        print("Actual folder feedback ownership passed: completed old action cannot publish into a new library.")
    }

    @MainActor static func unpreparedDeletionChecks(parent: URL) async throws {
        let root = parent.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("Synthetic pending cleanup audio".utf8).write(to: root.appendingPathComponent("Meeting.mp3"))
        try await TranscriptStore(baseDirectory: root).save(Transcript(recordingFilename: "Meeting.mp3", transcriptionModel: "fixture", hasSpeakerLabels: false,
            segments: [.init(startTime: 0, endTime: 1, text: "Pending preparation")]), mp3Filename: "Meeting.mp3")
        let a = SharedLibraryCoordinator(root: root, writerID: UUID(), witnessDirectory: parent.appendingPathComponent("local"), trash: { try FileManager.default.removeItem(at: $0) })
        _ = try await a.enable(); _ = try await a.projectOutputs()
        let original = try await a.recording(at: "Meeting.mp3")
        let deleted = try await a.resolve(.init(base: original, changes: [.delete]))
        let file = root.appendingPathComponent("Meeting.transcript.json")
        let canonical = try Data(contentsOf: file)
        var changed = try JSONSerialization.jsonObject(with: canonical) as! [String: Any]
        var segments = changed["segments"] as! [[String: Any]]
        segments[0]["text"] = "Unreviewed replacement content"; changed["segments"] = segments
        try JSONSerialization.data(withJSONObject: changed).write(to: file)
        do { _ = try await a.prepareReviewedDeletion(deleted); throw Failure(message: "Unreviewed changed sidecar must prevent cleanup preparation") }
        catch let failure as Failure { throw failure }
        catch {}
        try expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Meeting.mp3").path), "Failed preparation must preserve the synthetic original")
        let model = RecordingFileReviewState()
        await model.refresh(using: a)
        guard let candidate = model.deletionPreparations.first(where: { $0.id == original.state.id }) else { throw Failure(message: "A semantic delete without a recipe needs a native Retry Cleanup Preparation action") }
        try expect(!(await model.prepareDeletion(candidate, using: a)) && !model.deletionPreparations.isEmpty, "Failed retry must leave its preparation action available")
        try expect(!(await model.keepForReview(id: UUID(), using: a)), "An undisplayed identity cannot withdraw deletion")
        _ = try await a.resolve(.init(base: try await a.recording(at: "Meeting.mp3"), changes: [.restore, .assign(field: "metadata.mode", value: .text("\"Pho\"")), .delete]))
        try expect(!(await model.keepForReview(id: candidate.id, using: a)), "Changed semantic state must reject stale Keep consent")
        try expect(try await a.recording(at: "Meeting.mp3").state.lifecycle == .deleted, "Rejected stale Keep cannot restore the recording")
        try expect(await model.keepForReview(id: candidate.id, using: a), "Explicit Keep must withdraw deletion before external-file comparison")
        let kept = try await a.recording(at: "Meeting.mp3")
        try expect(kept.state.lifecycle == .alive, "Keep for review must restore the exact identity")
        let external = ExternalSidecarReviewState()
        await external.refresh(using: a)
        guard let row = external.items.first(where: { $0.review?.filename == "Meeting.mp3" }) else { throw Failure(message: "Kept recording must offer the actual external-file comparison") }
        try expect(await external.apply(row, useChangedFile: false, using: a), "Native Restore Current must repair the sidecar without fixture writes")
        try expect(external.message == "Current content restored.", "Native recovery must finish publication")
        let repaired = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        try expect((repaired["segments"] as? [[String: Any]])?.first?["text"] as? String == "Pending preparation", "Explicit recovery restores current transcript")
        let deleteAgain = try await a.resolve(.init(base: try await a.recording(at: "Meeting.mp3"), changes: [.delete]))
        await model.refresh(using: a)
        guard let next = model.deletionPreparations.first(where: { $0.id == deleteAgain.state.id }) else { throw Failure(message: "Deletion after native recovery must remain preparable") }
        try expect(await model.prepareDeletion(next, using: a), "Retry must finish deletion after native file recovery")
        try expect(model.deletionPreparations.isEmpty && model.items.isEmpty, "Completed deletion must not leave a false retry candidate")
        try expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Meeting.mp3").path), "Explicit retry may finish safe synthetic cleanup")
        print("Actual unprepared deletion passed: retry, explicit Keep, native external-file restoration and deletion again complete without fixture repair writes.")
    }

    @MainActor static func folderPathChecks(parent: URL) async throws {
        for stage in ["unstarted", "attempted", "published"] {
            let directory = parent.appendingPathComponent(stage), left = directory.appendingPathComponent("left"), right = directory.appendingPathComponent("right")
            for path in ["Folder/Nested", "Target"] { try FileManager.default.createDirectory(at: left.appendingPathComponent(path), withIntermediateDirectories: true) }
            let audio = Data("Synthetic folder conversation".utf8), nested = Data("Synthetic nested conversation".utf8), notes = Data("Preserve ordinary hidden notes".utf8)
            try audio.write(to: left.appendingPathComponent("Folder/A.mp3")); try nested.write(to: left.appendingPathComponent("Folder/Nested/B.mp3")); try notes.write(to: left.appendingPathComponent("Folder/.notes"))
            try await TranscriptStore(baseDirectory: left).save(Transcript(recordingFilename: "Folder/A.mp3", transcriptionModel: "fixture", hasSpeakerLabels: false,
                segments: [.init(startTime: 0, endTime: 1, text: "Folder conversation")]), mp3Filename: "Folder/A.mp3")
            let writer = UUID(), local = directory.appendingPathComponent("a-local")
            let seed = SharedLibraryCoordinator(root: left, writerID: writer, witnessDirectory: local)
            _ = try await seed.enable(); _ = try await seed.projectOutputs()
            let views = try await seed.snapshots(kinds: [.folder])
            guard let original = views.first(where: { $0.state.value(for: "name") == .text("Folder") }), let target = views.first(where: { $0.state.value(for: "name") == .text("Target") }) else { throw Failure(message: "Missing seeded folders") }
            let entity = SharedEntityIdentity(id: original.state.id, kind: .folder)
            let child = try await seed.reference(to: "Folder/A.mp3"), nestedChild = try await seed.reference(to: "Folder/Nested/B.mp3")
            try FileManager.default.copyItem(at: left, to: right)
            let b = SharedLibraryCoordinator(root: right, writerID: UUID(), witnessDirectory: directory.appendingPathComponent("b-local"), afterCommit: { withUnsafeCurrentTask { $0?.cancel() } })
            try await b.requestEnrollment(requestID: UUID(), label: "Folder peer")
            for _ in 0..<3 { try deliver(right, to: left, writer: b.writerID); try await seed.refresh(); try deliver(left, to: right, writer: seed.writerID); try await b.refresh() }
            let a = SharedLibraryCoordinator(root: left, writerID: writer, witnessDirectory: local, afterCommit: { if stage == "unstarted" { withUnsafeCurrentTask { $0?.cancel() } } })
            let own = Task { try await a.renameFolder(from: "Folder", to: "Local", afterMutation: { _ in if stage == "attempted" { throw CancellationError() } }) }
            do { _ = try await own.value; try expect(stage == "published", "Expected interrupted local folder move") } catch is CancellationError { }
            do { _ = try await Task { try await b.renameFolder(from: "Folder", to: "Peer") }.value; throw Failure(message: "Expected interrupted peer folder move") } catch is CancellationError { }
            // A parent change is independent of the competing names; the chosen
            // complete destination must honor that stable parent ID.
            do { _ = try await Task { try await b.edit(.init(base: try await b.read(entity), changes: [.assign(field: "parent", value: .text(target.state.id.uuidString))])) }.value } catch is CancellationError { }
            try deliver(right, to: left, writer: b.writerID)
            let pending = FolderFileReviewState(), pause = SavePause()
            let current = SharedLibraryCoordinator(root: left, writerID: writer, witnessDirectory: local, afterPublishedLibraryRead: {
                if stage == "unstarted", await MainActor.run(body: { pending.isWorking && pending.isLoading }) { await pause.pauseOnce() }
            })
            let model = SharedLibraryReviewState(); await model.refresh(using: current)
            guard let item = model.items.first(where: { $0.id == entity.id }), let field = item.fields.first(where: { $0.id == "folder.path" }),
                  let selected = field.choices.first(where: { $0.value == .text("Target/Peer") }) else { throw Failure(message: "Competing folder names must offer a complete validated location; stage=" + stage) }
            try expect(selected.detail.contains("Folder peer"), "Folder choice identifies contributing Mac")
            try expect(await model.apply(item: item, selections: [field.id: selected.id], using: current), "Actual folder review saves exact selected name/parent")
            let source = stage == "unstarted" ? "Folder" : "Local"
            try expect(try Data(contentsOf: left.appendingPathComponent(source + "/A.mp3")) == audio, "Semantic folder choice preserves original bytes before physical review")
            try expect(child.entityID != nestedChild.entityID, "Distinct child identities remain available")
            await pending.refresh(using: current)
            guard let row = pending.items.first(where: { $0.id == entity.id }), row.canReplan else { throw Failure(message: "Selected folder path needs an actionable updated plan; stage=" + stage + "; feedback=" + (pending.message ?? "nil")) }
            await pending.prepareUpdatedPlan(row, using: current)
            guard let plan = pending.updatedPlan else { throw Failure(message: "Folder updated plan must be inspectable; stage=" + stage + "; feedback=" + (pending.message ?? "nil")) }
            try expect(plan.source == source && plan.destination == "Target/Peer", "Reviewed directory plan uses actual source and complete selected path")
            if stage == "unstarted" {
                let action = Task { await pending.applyUpdatedPlan(using: current) }
                for _ in 0..<500 { if await pause.entered { break }; try await Task.sleep(for: .milliseconds(20)) }
                guard await pause.entered else { action.cancel(); await pause.release(); _ = await action.value; throw Failure(message: "Updated folder plan did not reach held feedback refresh") }
                pending.clear()
                let otherRoot = directory.appendingPathComponent("other-library")
                try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
                let other = SharedLibraryCoordinator(root: otherRoot, writerID: UUID(), witnessDirectory: directory.appendingPathComponent("other-local"))
                _ = try await other.enable(); await pending.refresh(using: other)
                await pause.release(); _ = await action.value
                try expect(pending.message == nil && pending.items.isEmpty && !pending.isWorking && !pending.isLoading, "Old updated-plan feedback must not cross a library switch during refresh")
            } else { try expect(await pending.applyUpdatedPlan(using: current), "Actual reviewed folder plan finishes") }
            try expect(try Data(contentsOf: left.appendingPathComponent("Target/Peer/A.mp3")) == audio, "Original child audio preserved exactly")
            try expect(try Data(contentsOf: left.appendingPathComponent("Target/Peer/Nested/B.mp3")) == nested, "Nested child audio preserved exactly")
            try expect(try Data(contentsOf: left.appendingPathComponent("Target/Peer/.notes")) == notes, "Ordinary hidden file moves without replacement")
            try expect(!FileManager.default.fileExists(atPath: left.appendingPathComponent("Folder").path) && !FileManager.default.fileExists(atPath: left.appendingPathComponent("Local").path), "Completed folder recovery leaves no source directory duplicate")
            try expect(try await current.reference(to: "Target/Peer/A.mp3") == child, "First child retains stable identity")
            try expect(try await current.reference(to: "Target/Peer/Nested/B.mp3") == nestedChild, "Nested child retains stable identity")
            let transcript = try await TranscriptStore(baseDirectory: left).loadTranscript(for: "Target/Peer/A.mp3")
            try expect(transcript?.segments.first?.text == "Folder conversation", "Transcript follows the selected directory path")
            try expect((try await current.read(entity)).state.conflicts.isEmpty, "Physical bookkeeping conflicts resolve through reviewed continuation")
            print("Actual folder path recovery stage passed: " + stage)
        }
    }

    @MainActor static func recordingPathChecks(parent: URL) async throws {
        let stages = CommandLine.arguments.contains("--recording-path-deleted-published-only") ? ["deleted-published"] : CommandLine.arguments.contains("--recording-path-published-only") ? ["published"] : ["unstarted", "partial", "published", "deleted-unstarted", "deleted-partial", "deleted-published"]
        for stage in stages {
            let deleted = stage.hasPrefix("deleted-")
            let phase = deleted ? String(stage.dropFirst("deleted-".count)) : stage
            let directory = parent.appendingPathComponent(stage), left = directory.appendingPathComponent("left"), right = directory.appendingPathComponent("right")
            try FileManager.default.createDirectory(at: left.appendingPathComponent("Target"), withIntermediateDirectories: true)
            let audio = Data("Synthetic original for path conflict".utf8)
            try audio.write(to: left.appendingPathComponent("Meeting.mp3"))
            try await TranscriptStore(baseDirectory: left).save(Transcript(recordingFilename: "Meeting.mp3", transcriptionModel: "fixture", hasSpeakerLabels: false,
                segments: [.init(startTime: 0, endTime: 1, text: "Retained conversation")]), mp3Filename: "Meeting.mp3")
            try await SummaryStore(baseDirectory: left).save(Summary(recordingFilename: "Meeting.mp3", model: "fixture", provider: "fixture", templateUsed: "meeting",
                sections: [.init(heading: "Notes", content: "Retained summary")]), mp3Filename: "Meeting.mp3")
            let writer = UUID(), local = directory.appendingPathComponent("a-local")
            let seed = SharedLibraryCoordinator(root: left, writerID: writer, witnessDirectory: local)
            _ = try await seed.enable(); _ = try await seed.projectOutputs()
            try FileManager.default.copyItem(at: left, to: right)
            let b = SharedLibraryCoordinator(root: right, writerID: UUID(), witnessDirectory: directory.appendingPathComponent("b-local"), afterCommit: { withUnsafeCurrentTask { $0?.cancel() } })
            // Enrollment itself does not use the user-mutation callback.
            try await b.requestEnrollment(requestID: UUID(), label: "Path peer")
            for _ in 0..<3 {
                try deliver(right, to: left, writer: b.writerID); try await seed.refresh()
                try deliver(left, to: right, writer: seed.writerID); try await b.refresh()
            }
            let a = SharedLibraryCoordinator(root: left, writerID: writer, witnessDirectory: local,
                afterCommit: { if phase == "unstarted" { withUnsafeCurrentTask { $0?.cancel() } } })
            let entity = SharedEntityIdentity(id: try await a.reference(to: "Meeting.mp3").entityID, kind: .recording)
            let own = Task { try await a.relocateRecording(filename: "Meeting.mp3", title: "Local", toFolder: "Target", changeFolder: true, afterMutation: { _ in
                if phase == "partial" { throw CancellationError() }
            }) }
            do { _ = try await own.value; try expect(phase == "published", "Expected actual interrupted move") } catch is CancellationError { }
            let peer = Task { try await b.relocateRecording(filename: "Meeting.mp3", title: "Peer", toFolder: "Target", changeFolder: true) }
            do { _ = try await peer.value; throw Failure(message: "Expected interrupted peer move") } catch is CancellationError { }
            try deliver(right, to: left, writer: b.writerID)
            let current = SharedLibraryCoordinator(root: left, writerID: writer, witnessDirectory: local,
                trash: { try FileManager.default.removeItem(at: $0) })
            print("Path stage " + stage + ": before lifecycle decision")
            if deleted { _ = try await current.resolve(.init(base: try await current.read(entity), changes: [.delete])) }
            print("Path stage " + stage + ": before semantic review")
            let model = SharedLibraryReviewState(); await model.refresh(using: current)
            guard var item = model.items.first(where: { $0.id == entity.id }),
                  var path = item.fields.first(where: { $0.id == "recording.path" }),
                  var selected = path.choices.first(where: { $0.value == .text("Target/Peer.mp3") }) else { throw Failure(message: "Competing paths must offer validated readable location choices") }
            try expect(selected.detail.contains("Path peer"), "Path choice identifies the peer name source")
            if stage == "unstarted" {
                let beforeSignature = item.reviewSignature
                let folders = try await current.snapshots(kinds: [.folder])
                guard let folder = folders.first(where: { $0.state.value(for: "name") == .text("Target") }) else { throw Failure(message: "Missing target folder") }
                let folderID = SharedEntityIdentity(id: folder.state.id, kind: .folder)
                _ = try await current.edit(.init(base: folder, changes: [.delete]))
                _ = try await current.resolve(.init(base: try await current.read(folderID), changes: [.restore]))
                try expect(!(await model.apply(item: item, selections: [path.id: selected.id], using: current)), "Old destination lifecycle consent must refuse")
                await model.refresh(using: current)
                guard let fresh = model.items.first(where: { $0.id == entity.id }), let next = fresh.fields.first(where: { $0.id == "recording.path" }),
                      let choice = next.choices.first(where: { $0.value == .text("Target/Peer.mp3") }) else { throw Failure(message: "Reloaded path choices missing") }
                try expect(fresh.reviewSignature != beforeSignature, "A refreshed ABA destination must clear the UI's old selection consent")
                item = fresh; path = next; selected = choice
            }

            print("Path stage " + stage + ": before path acceptance")
            try expect(await model.apply(item: item, selections: [path.id: selected.id], using: current), "Actual review saves the selected path")
            let pending = RecordingFileReviewState(); await pending.refresh(using: current)
            guard let row = pending.items.first(where: { $0.id == entity.id }), row.canReplan else { throw Failure(message: "Selected path must lead to a usable updated physical plan; stage=" + stage + "; rows=" + String(pending.items.count) + "; inspection=" + String(pending.inspectionFailed) + "; feedback=" + (pending.message ?? "nil")) }
            print("Path stage " + stage + ": before physical preview")
            await pending.prepareUpdatedPlan(row, using: current)
            guard let plan = pending.updatedPlan else {
                _ = try await current.prepareRecordingReplan(row)
                throw Failure(message: "Updated path plan must be inspectable; stage=" + stage)
            }
            try expect(plan.destination == "Target/Peer.mp3", "Physical plan follows the exact selected path")
            try expect(plan.isDeletion == deleted, "Deleted path decisions need an explicit cleanup review")
            print("Path stage " + stage + ": before physical acceptance")
            try expect(await pending.applyUpdatedPlan(using: current), "Reviewed physical continuation completes or awaits approval")
            if deleted {
                try expect((try await current.read(entity)).state.lifecycle == .deleted, "Path decision cannot reverse Delete")
                let source = phase == "unstarted" ? "Meeting.mp3" : "Target/Local.mp3"
                try expect(try Data(contentsOf: left.appendingPathComponent(source)) == audio, "Offline peer prevents removal of exact original audio")
                print("Path stage " + stage + ": before peer delivery")
                try deliver(left, to: right, writer: current.writerID); try await b.refresh()
                // Explicit synthetic provider delivery: the peer must see the
                // actual moved files, not approve a plan that omits its still-
                // resident old originals. This is not real-provider acceptance.
                for stem in ["Meeting", "Target/Local", "Target/Peer"] {
                    for suffix in [".mp3", ".transcript.json", ".summary.json", ".txt", ".transcript.md", ".summary.md"] {
                        let source = left.appendingPathComponent(stem + suffix), target = right.appendingPathComponent(stem + suffix)
                        if FileManager.default.fileExists(atPath: source.path) {
                            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                            try Data(contentsOf: source).write(to: target, options: .atomic)
                        } else if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                    }
                }
                print("Path stage " + stage + ": before peer approval")
                if phase == "published" {
                    // Registry metadata arrived before its replacement canonical
                    // document. Refuse consent until that real provider delivery
                    // completes; do not bless the peer's superseded document.
                    do { try await b.acknowledgeOperation(entity: entity, purpose: .delete); throw Failure(message: "Out-of-order canonical metadata must prevent approval") }
                    catch SharedProjectionWriteError.untracked(let path) { try expect(path == "library.json", "Expected the held canonical document") }
                    try expect(try Data(contentsOf: left.appendingPathComponent(source)) == audio, "Missing peer metadata cannot authorize removal")
                    try Data(contentsOf: left.appendingPathComponent("library.json")).write(to: right.appendingPathComponent("library.json"), options: .atomic)
                }
                try await b.acknowledgeOperation(entity: entity, purpose: .delete)
                try deliver(right, to: left, writer: b.writerID)
                let restarted = SharedLibraryCoordinator(root: left, writerID: writer, witnessDirectory: local,
                    trash: { try FileManager.default.removeItem(at: $0) })
                print("Path stage " + stage + ": before owner restart/resume")
                let removed = try await restarted.resumeRecordingOperation(id: entity.id)
                try expect(removed.result == .complete, "Fresh peer approval and restart finish the accepted cleanup")
                for stem in ["Meeting", "Target/Local", "Target/Peer"] {
                    for suffix in [".mp3", ".transcript.json", ".summary.json", ".txt", ".transcript.md", ".summary.md"] {
                        try expect(!FileManager.default.fileExists(atPath: left.appendingPathComponent(stem + suffix).path), "No known alias remains after approved cleanup")
                    }
                }
                print("Actual recording path stage passed: " + stage)
                continue
            }
            try expect(try Data(contentsOf: left.appendingPathComponent("Target/Peer.mp3")) == audio, "Original audio remains exact")
            try expect(!FileManager.default.fileExists(atPath: left.appendingPathComponent("Meeting.mp3").path)
                && !FileManager.default.fileExists(atPath: left.appendingPathComponent("Target/Local.mp3").path), "No original-path duplicate left after completed recovery")
            let transcript = try await TranscriptStore(baseDirectory: left).loadTranscript(for: "Target/Peer.mp3")
            try expect(transcript?.segments.first?.text == "Retained conversation", "Companion remains associated after path recovery")
            let summary = try await SummaryStore(baseDirectory: left).loadSummary(for: "Target/Peer.mp3")
            try expect(summary?.sections.first?.content == "Retained summary", "Summary and all derived companions follow the selected path")
            try expect((try await current.read(entity)).state.conflicts.isEmpty, "Path conflict resolved without replacing recording identity")
            print("Actual recording path stage passed: " + stage)
        }
        print("Actual recording path recovery passed: alive/deleted unstarted, partial and published moves lead from explicit path choice to reviewed physical continuation.")
    }

    @MainActor static func sourceMacChecks(parent: URL) async throws {
        let left = parent.appendingPathComponent("left"), right = parent.appendingPathComponent("right"), third = parent.appendingPathComponent("third")
        try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
        let template = Template.makeUserTemplate(name: "Sources", description: "Source fixture", promptText: "Initial prompt")
        try await TemplateStore(baseDirectory: left).addUserTemplate(template)
        let a = SharedLibraryCoordinator(root: left, writerID: UUID(uuidString: "aaaaaaaa-0000-0000-0000-000000000001")!, witnessDirectory: parent.appendingPathComponent("a-local"))
        _ = try await a.enable(); _ = try await a.projectOutputs()
        try FileManager.default.copyItem(at: left, to: right); try FileManager.default.copyItem(at: left, to: third)
        let b = SharedLibraryCoordinator(root: right, writerID: UUID(uuidString: "bbbbbbbb-0000-0000-0000-000000000002")!, witnessDirectory: parent.appendingPathComponent("b-local"))
        let c = SharedLibraryCoordinator(root: third, writerID: UUID(uuidString: "cccccccc-0000-0000-0000-000000000003")!, witnessDirectory: parent.appendingPathComponent("c-local"))
        try await b.requestEnrollment(requestID: UUID(), label: "Peer Mac")
        try await c.requestEnrollment(requestID: UUID(), label: "Peer Mac")
        for _ in 0..<5 {
            try deliver(right, to: left, writer: b.writerID); try deliver(third, to: left, writer: c.writerID); try await a.refresh()
            try deliver(left, to: right, writer: a.writerID); try deliver(third, to: right, writer: c.writerID); try await b.refresh()
            try deliver(left, to: third, writer: a.writerID); try deliver(right, to: third, writer: b.writerID); try await c.refresh()
        }
        try expect(try await b.mayEdit(), "B must enroll"); try expect(try await c.mayEdit(), "C must enroll")
        do { _ = try await a.writerLabels(libraryID: UUID()); throw Failure(message: "Foreign library must not borrow writer labels") }
        catch SharedLibraryCoordinatorError.differentBinding { }
        let original = try await a.snapshots(kinds: [.template]).first { $0.state.value(for: "templateID") == .text(template.id) }!
        let entity = SharedEntityIdentity(id: original.state.id, kind: .template)
        let baseB = try await b.read(entity), baseC = try await c.read(entity)
        _ = try await a.edit(.init(base: original, changes: [.assign(field: "prompt", value: .text("Local prompt"))]))
        _ = try await b.edit(.init(base: baseB, changes: [.assign(field: "prompt", value: .text("Shared peer prompt"))]))
        _ = try await c.edit(.init(base: baseC, changes: [.assign(field: "prompt", value: .text("Shared peer prompt"))]))
        try deliver(right, to: left, writer: b.writerID); try deliver(third, to: left, writer: c.writerID)
        let model = SharedLibraryReviewState(); await model.refresh(using: a)
        guard let field = model.items.first?.fields.first,
              let own = field.choices.first(where: { $0.value == .text("Local prompt") }),
              let peers = field.choices.first(where: { $0.value == .text("Shared peer prompt") }) else { throw Failure(message: "Missing actual three-Mac choices") }
        try expect(own.detail.contains("This Mac"), "Local competing value identifies this Mac")
        try expect(peers.detail.contains("Peer Mac") && peers.detail.contains("bbbbbbbb") && peers.detail.contains("cccccccc"), "Identical value must show both contributing Macs with distinguishable duplicate labels")
        try expect(!peers.detail.contains("This Mac"), "Consumed original author is not the source of identical peer values")
        // B observes all alternatives and resolves them, while C edits offline.
        try deliver(left, to: right, writer: a.writerID); try deliver(third, to: right, writer: c.writerID)
        _ = try await b.resolve(.init(base: try await b.read(entity), changes: [.assign(field: "prompt", value: .text("Resolved by B"))]))
        _ = try await c.edit(.init(base: try await c.read(entity), changes: [.assign(field: "prompt", value: .text("Late C edit"))]))
        try deliver(right, to: left, writer: b.writerID); try deliver(third, to: left, writer: c.writerID)
        await model.refresh(using: a)
        guard let resolved = model.items.first?.fields.first?.choices.first(where: { $0.value == .text("Resolved by B") }) else { throw Failure(message: "Missing new offline conflict") }
        try expect(resolved.detail.contains("bbbbbbbb") && !resolved.detail.contains("cccccccc") && !resolved.detail.contains("This Mac"), "Current contributor excludes all consumed writers after resolution")
        model.clear(); try expect(model.items.isEmpty, "Clearing library binding removes old attribution")
        print("Actual source attribution passed: three independent roots, identical contributors, duplicate labels and consumed-writer exclusion.")
    }

    @MainActor static func templateLifecycleChecks(parent: URL) async throws {
        for keep in [true, false] {
            let directory = parent.appendingPathComponent(keep ? "keep" : "delete"), left = directory.appendingPathComponent("left"), right = directory.appendingPathComponent("right")
            try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
            let user = Template.makeUserTemplate(name: "Contested template", description: "Original description", promptText: "Original prompt")
            let other = Template.makeUserTemplate(name: "Unrelated template", description: "Keep this", promptText: "Unrelated prompt")
            let legacy = TemplateStore(baseDirectory: left)
            try await legacy.addUserTemplate(user); try await legacy.addUserTemplate(other)
            let a = SharedLibraryCoordinator(root: left, writerID: UUID(), witnessDirectory: directory.appendingPathComponent("a-local"))
            _ = try await a.enable(); _ = try await a.projectOutputs()
            try FileManager.default.copyItem(at: left, to: right)
            let b = SharedLibraryCoordinator(root: right, writerID: UUID(), witnessDirectory: directory.appendingPathComponent("b-local"))
            try await b.requestEnrollment(requestID: UUID(), label: "Template editing Mac")
            for _ in 0..<3 {
                try deliver(right, to: left, writer: b.writerID); try await a.refresh()
                try deliver(left, to: right, writer: a.writerID); try await b.refresh()
            }
            let storeA = TemplateStore(baseDirectory: left, shared: SharedTemplateAdapter(coordinator: a))
            let storeB = TemplateStore(baseDirectory: right, shared: SharedTemplateAdapter(coordinator: b))
            try await storeA.load(); try await storeB.load()
            var first = user; first.promptText = "Retained prompt A"
            var second = user; second.promptText = "Retained prompt B"
            try await storeA.update(first); try await storeA.delete(id: user.id)
            try await storeB.update(second)
            try deliver(right, to: left, writer: b.writerID)
            let model = SharedLibraryReviewState(); await model.refresh(using: a)
            guard let item = model.items.first(where: { $0.snapshot.state.kind == .template }),
                  let field = item.fields.first(where: { $0.id == "$lifecycle" }) else { throw Failure(message: "Template lifecycle conflict must have a row") }
            try expect(field.choices.count == 2, "Template delete-versus-edit must offer explicit Keep/Delete decisions")
            try expect(field.choices.first { $0.value == .flag(false) }?.detail.contains("From: This Mac") == true
                && field.choices.first { $0.value == .flag(true) }?.detail.contains("From: Template editing Mac") == true, "Lifecycle choices identify their current source Macs")
            try expect(field.choices.allSatisfy { $0.detail.contains("From: This Mac\nRetained prompt A") && $0.detail.contains("From: Template editing Mac\nRetained prompt B") }, "Retained template alternatives identify their own sources")
            try expect(field.choices.allSatisfy { $0.detail.contains("Retained prompt A") && $0.detail.contains("Retained prompt B") }, "Template lifecycle choices must preview both retained prompts")
            guard let choice = field.choices.first(where: { $0.value == .flag(keep) }) else { throw Failure(message: "Missing template decision") }
            // A new field write changes the reviewed lifecycle context too.
            let changed = try await a.read(.init(id: item.id, kind: .template))
            _ = try await a.resolve(.init(base: changed, changes: [.restore, .assign(field: "description", value: .text("New retained description"))]))
            try expect(!(await model.apply(item: item, selections: [field.id: choice.id], using: a)), "An unseen template edit must invalidate the old lifecycle choice")
            // Recreate delete-vs-edit concurrently after the controlled stale attempt.
            _ = try await a.edit(.init(base: try await a.read(.init(id: item.id, kind: .template)), changes: [.delete]))
            var third = second; third.description = "Offline description"
            try await storeB.update(third); try deliver(right, to: left, writer: b.writerID)
            await model.refresh(using: a)
            guard let current = model.items.first(where: { $0.id == item.id }), let lifecycle = current.fields.first(where: { $0.id == "$lifecycle" }),
                  let selected = lifecycle.choices.first(where: { $0.value == .flag(keep) }) else { throw Failure(message: "Reloaded template lifecycle choice missing") }
            try expect(await model.apply(item: current, selections: [lifecycle.id: selected.id], using: a), "Template lifecycle choice saves through actual review model")
            guard let retained = model.items.first(where: { $0.id == item.id }), let prompts = retained.fields.first(where: { $0.id == "prompt" }),
                  let promptB = prompts.choices.first(where: { $0.value == .text("Retained prompt B") }) else { throw Failure(message: "Retained prompt conflict remains actionable for both Keep and Delete") }
            var decisions = [prompts.id: promptB.id]
            for field in retained.visibleFields(selections: decisions) where !field.choices.isEmpty && field.id != prompts.id {
                guard let selected = field.choices.first(where: { $0.value == .text("Offline description") }) ?? field.choices.first else { throw Failure(message: "Missing retained field decision") }
                decisions[field.id] = selected.id
            }
            try expect(await model.apply(item: retained, selections: decisions, using: a), "Retained template content resolves without changing chosen lifecycle")
            let accepted = try await a.read(.init(id: item.id, kind: .template))
            try expect(accepted.state.lifecycle == (keep ? .alive : .deleted) && accepted.state.conflicts.isEmpty, "Template review preserves chosen lifecycle and resolves the retained edits")
            try expect(accepted.state.value(for: "prompt") == .text("Retained prompt B"), "Selected template prompt remains stored even after Delete")
            try await storeA.load()
            try expect(await storeA.template(forID: other.id) == other, "Unrelated template remains usable")
            try expect((await storeA.template(forID: user.id) != nil) == keep, "Catalog reflects explicit Keep/Delete choice")
            try deliver(left, to: right, writer: a.writerID); try await b.refresh()
            let converged = try await b.read(.init(id: item.id, kind: .template))
            try expect(converged.state == accepted.state, "Replica converges on lifecycle and retained content")
        }
        print("Actual template lifecycle passed: readable Keep/Delete, stale refusal, retained content after Delete, catalog and replica convergence.")
    }

    @MainActor static func lifecycleReviewChecks(parent: URL) async throws {
        for keep in [true, false] { try await lifecycleReviewCase(parent: parent.appendingPathComponent(keep ? "keep" : "delete"), keep: keep) }
        try await lifecycleReviewCase(parent: parent.appendingPathComponent("delete-with-content"), keep: false, competing: true)
        print("Actual lifecycle choices passed: Keep/Delete preserve edits and files, stale decisions refuse, replicas converge, deleted content remains reviewable.")
    }
    @MainActor static func lifecycleReviewCase(parent: URL, keep: Bool, competing: Bool = false) async throws {
        let left = parent.appendingPathComponent("left"), right = parent.appendingPathComponent("right")
        try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
        let audio = Data("Synthetic lifecycle original".utf8)
        try audio.write(to: left.appendingPathComponent("Meeting.mp3"))
        try await TranscriptStore(baseDirectory: left).save(Transcript(recordingFilename: "Meeting.mp3", transcriptionModel: "fixture", hasSpeakerLabels: true,
            segments: [.init(startTime: 0, endTime: 1, text: "Retain offline edits", speakerID: "s")]), mp3Filename: "Meeting.mp3")
        let a = SharedLibraryCoordinator(root: left, writerID: UUID(), witnessDirectory: parent.appendingPathComponent("a-local"))
        _ = try await a.enable(); _ = try await a.projectOutputs()
        try FileManager.default.copyItem(at: left, to: right)
        let b = SharedLibraryCoordinator(root: right, writerID: UUID(), witnessDirectory: parent.appendingPathComponent("b-local"))
        try await b.requestEnrollment(requestID: UUID(), label: "Offline editing Mac")
        for _ in 0..<3 {
            try deliver(right, to: left, writer: b.writerID); try await a.refresh()
            try deliver(left, to: right, writer: a.writerID); try await b.refresh()
        }
        try expect(try await b.mayEdit(), "Lifecycle peer must enroll before offline edits")
        let baseA = try await a.recording(at: "Meeting.mp3"), baseB = try await b.recording(at: "Meeting.mp3")
        guard let document = baseB.state.currentDocument(for: .transcript) else { throw Failure(message: "Missing lifecycle transcript") }
        if competing {
            let encoder = JSONEncoder()
            let first = try SharedDocument(id: UUID(), json: encoder.encode(Transcript(recordingFilename: "Meeting.mp3", transcriptionModel: "A", hasSpeakerLabels: false,
                segments: [.init(startTime: 0, endTime: 1, text: "Retained version A")])))
            let second = try SharedDocument(id: UUID(), json: encoder.encode(Transcript(recordingFilename: "Meeting.mp3", transcriptionModel: "B", hasSpeakerLabels: false,
                segments: [.init(startTime: 0, endTime: 1, text: "Retained version B")])))
            let replaced = try await a.edit(.init(base: baseA, changes: [.generation(first, component: .transcript)]))
            _ = try await a.edit(.init(base: replaced, changes: [.delete]))
            _ = try await b.edit(.init(base: baseB, changes: [.generation(second, component: .transcript)]))
            try deliver(right, to: left, writer: b.writerID)
            let model = SharedLibraryReviewState(); await model.refresh(using: a)
            guard let item = model.items.first(where: { $0.id == baseA.state.id }), let field = item.fields.first(where: { $0.id == "$lifecycle" }),
                  let remove = field.choices.first(where: { $0.value == .flag(false) }) else { throw Failure(message: "Missing mixed lifecycle decision") }
            try expect(await model.apply(item: item, selections: [field.id: remove.id], using: a), "Mixed conflict must accept explicit deletion while preserving competing content")
            guard let contentItem = model.items.first(where: { $0.id == item.id }), let versions = contentItem.fields.first(where: { $0.id == "transcript.content" }),
                  let keepVersion = versions.choices.first(where: { $0.value == .document(second) }) else { throw Failure(message: "A deleted recording must keep its competing content actionable before cleanup") }
            try expect(await model.apply(item: contentItem, selections: [versions.id: keepVersion.id], using: a), "Content review must resolve without restoring the deleted recording")
            let accepted = try await a.read(.init(id: item.id, kind: .recording))
            try expect(accepted.state.lifecycle == .deleted && accepted.state.currentDocument(for: .transcript)?.id == second.id && accepted.state.conflicts.isEmpty, "Review must retain the selected content and the user's deletion decision")
            let pending = RecordingFileReviewState(); await pending.refresh(using: a)
            try expect(pending.items.contains(where: { $0.id == item.id && $0.purpose == .delete }), "Resolved deleted content must have safe cleanup available")
            try expect(try Data(contentsOf: left.appendingPathComponent("Meeting.mp3")) == audio, "Offline peer still vetoes physical cleanup")
            return
        }
        _ = try await a.edit(.init(base: baseA, changes: [.delete]))
        _ = try await b.edit(.init(base: baseB, changes: [.generationEdit(component: .transcript, generation: document.id, key: "s", value: .text("Offline Alice"))]))
        try deliver(right, to: left, writer: b.writerID)
        let model = SharedLibraryReviewState()
        await model.refresh(using: a)
        guard let item = model.items.first(where: { $0.id == baseA.state.id }), let lifecycle = item.fields.first(where: { $0.id == "$lifecycle" }) else { throw Failure(message: "Missing actual delete-versus-edit review") }
        try expect(Set(lifecycle.choices.map(\.value)) == [.flag(true), .flag(false)], "Actual lifecycle review must offer Keep Recording and Delete Recording decisions")
        guard let choice = lifecycle.choices.first(where: { $0.value == .flag(keep) }) else { throw Failure(message: "Missing lifecycle decision") }
        try expect(choice.detail.contains("Offline Alice") && choice.detail.contains("Retain offline edits"), "Lifecycle decisions must show the retained offline content and speaker edit")
        let newerB = try await b.read(.init(id: baseB.state.id, kind: .recording))
        _ = try await b.edit(.init(base: newerB, changes: [.generationEdit(component: .transcript, generation: document.id, key: "s", value: .text("Latest Alice"))]))
        try deliver(right, to: left, writer: b.writerID)
        try expect(!(await model.apply(item: item, selections: [lifecycle.id: choice.id], using: a)), "A lifecycle decision must refuse an edit received after review")
        try expect(model.message?.contains("changed during review") == true, "Stale lifecycle consent must explain reloading")
        await model.refresh(using: a)
        guard let fresh = model.items.first(where: { $0.id == item.id }), let field = fresh.fields.first(where: { $0.id == "$lifecycle" }), let current = field.choices.first(where: { $0.value == .flag(keep) }) else { throw Failure(message: "Missing fresh lifecycle decision") }
        try expect(fresh.reviewSignature != item.reviewSignature, "Refreshing lifecycle review after a new speaker edit must clear the native Keep/Delete selection")
        try expect(await model.apply(item: fresh, selections: [field.id: current.id], using: a), "Reviewed lifecycle decision must commit")
        let resolved = try await a.read(.init(id: item.id, kind: .recording))
        try expect(resolved.state.lifecycle == (keep ? .alive : .deleted), "Explicit Keep/Delete must resolve only the lifecycle")
        try expect(resolved.state.generationEdits(for: .transcript)["s"] == .text("Latest Alice"), "Lifecycle decision must retain the offline edit")
        try expect(try Data(contentsOf: left.appendingPathComponent("Meeting.mp3")) == audio, "Lifecycle decision must not remove or rewrite the original")
        try expect(model.message != nil, "Logical lifecycle acceptance must explain remaining physical work")
        if !keep {
            let pending = RecordingFileReviewState()
            await pending.refresh(using: a)
            try expect(pending.items.contains { $0.id == item.id && $0.purpose == .delete && !$0.waitingForMacs.isEmpty }, "Confirmed deletion must have a visible durable pending cleanup, not just a hidden semantic flag")
        }
        try deliver(left, to: right, writer: a.writerID)
        let peer = try await b.read(.init(id: item.id, kind: .recording))
        try expect(peer.state.lifecycle == resolved.state.lifecycle, "Peer must converge on the explicit decision")
        try deliver(right, to: left, writer: b.writerID)
        try expect(try await a.read(.init(id: item.id, kind: .recording)).state.lifecycle == resolved.state.lifecycle, "Old deletion/edit delivery must not undo the decision")
        model.clear()
        try expect(!(await model.apply(item: fresh, selections: [field.id: current.id], using: a)), "Cleared context cannot reuse lifecycle consent")
    }

    @MainActor static func run() async throws {
        _ = NSApplication.shared
        let arguments = CommandLine.arguments
        let ui = arguments.contains("--ui")
        let requestedParent: URL
        if let index = arguments.firstIndex(of: "--ui-root"), arguments.indices.contains(index + 1) { requestedParent = URL(fileURLWithPath: arguments[index + 1]) }
        else { requestedParent = FileManager.default.temporaryDirectory.appendingPathComponent("DockTapeReview-" + UUID().uuidString) }
        guard !FileManager.default.fileExists(atPath: requestedParent.path) else {
            throw Failure(message: "QA fixture root must be new; existing folders are never reused or removed.")
        }
        try FileManager.default.createDirectory(at: requestedParent, withIntermediateDirectories: true)
        // Resolve aliases only after the directory exists; macOS may spell a
        // missing /private/tmp descendant differently from its existing parent.
        let parent = requestedParent.standardizedFileURL.resolvingSymlinksInPath()
        defer { if !ui { try? FileManager.default.removeItem(at: parent) } }
        if arguments.contains("--folder-paths-only") { try await folderPathChecks(parent: parent); return }
        if arguments.contains("--recording-paths-only") || arguments.contains("--recording-path-published-only") || arguments.contains("--recording-path-deleted-published-only") { try await recordingPathChecks(parent: parent); return }
        if arguments.contains("--source-macs-only") { try await sourceMacChecks(parent: parent); return }
        if arguments.contains("--template-lifecycle-only") { try await templateLifecycleChecks(parent: parent); return }
        if arguments.contains("--folder-requests-only") { try await folderRequestConflictChecks(parent: parent); return }
        if arguments.contains("--folder-rejection-only") { try await rejectedFolderRenameChecks(parent: parent); return }
        if arguments.contains("--folder-feedback-only") { try await folderFeedbackChecks(parent: parent); return }
        if arguments.contains("--folder-interrupted-approval-only") { try await pendingFolderChecks(parent: parent, interruptBeforeOwnerApproval: true); return }
        if arguments.contains("--folders-only") {
            try await pendingFolderChecks(parent: parent.appendingPathComponent("normal"))
            try await pendingFolderChecks(parent: parent.appendingPathComponent("interrupted"), interruptBeforeOwnerApproval: true)
            return
        }
        if arguments.contains("--lifecycle-only") { try await lifecycleReviewChecks(parent: parent); try await unpreparedDeletionChecks(parent: parent.appendingPathComponent("unprepared")); return }
        try await folderPathChecks(parent: parent.appendingPathComponent("folder-paths"))
        try await recordingPathChecks(parent: parent.appendingPathComponent("recording-paths"))
        try await sourceMacChecks(parent: parent.appendingPathComponent("source-macs"))
        try await templateLifecycleChecks(parent: parent.appendingPathComponent("template-lifecycle"))
        try await folderRequestConflictChecks(parent: parent.appendingPathComponent("folder-requests"))
        try await pendingFolderChecks(parent: parent.appendingPathComponent("folders"))
        try await pendingFolderChecks(parent: parent.appendingPathComponent("folders-interrupted"), interruptBeforeOwnerApproval: true)
        try await rejectedFolderRenameChecks(parent: parent.appendingPathComponent("folder-rejection"))
        try await folderFeedbackChecks(parent: parent.appendingPathComponent("folder-feedback"))
        try await lifecycleReviewChecks(parent: parent.appendingPathComponent("lifecycle"))
        try await unpreparedDeletionChecks(parent: parent.appendingPathComponent("unprepared"))
        try await externalReviewChecks(parent: parent)
        let left = parent.appendingPathComponent("left"), right = parent.appendingPathComponent("right")
        try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
        try Data("synthetic audio".utf8).write(to: left.appendingPathComponent("Meeting.mp3"))
        try await TranscriptStore(baseDirectory: left).save(Transcript(recordingFilename: "Meeting.mp3", transcriptionModel: "fixture", hasSpeakerLabels: true,
            segments: [.init(startTime: 0, endTime: 1, text: "Synthetic conversation", speakerID: "s")]), mp3Filename: "Meeting.mp3")
        let identityFile = parent.appendingPathComponent("identity.json")
        let identity = try await SharedLibraryWriterIdentityStore(file: identityFile, installationAnchor: "synthetic review installation").load()
        let a = SharedLibraryCoordinator(root: left, writerID: identity.writer, witnessDirectory: parent.appendingPathComponent("a-local"))
        _ = try await a.enable()
        _ = try await a.projectOutputs()
        try FileManager.default.copyItem(at: left, to: right)
        let b = SharedLibraryCoordinator(root: right, writerID: UUID(), witnessDirectory: parent.appendingPathComponent("b-local"))
        try await b.requestEnrollment(requestID: UUID(), label: "Second test Mac")
        for _ in 0..<3 {
            try deliver(right, to: left, writer: b.writerID); try await a.refresh()
            try deliver(left, to: right, writer: a.writerID); try await b.refresh()
        }
        try expect(try await b.mayEdit(), "Second writer must enroll")
        let first = try await a.recording(at: "Meeting.mp3")
        let entity = SharedEntityIdentity(id: first.state.id, kind: .recording)
        guard let generation = first.state.currentDocument(for: .transcript) else { throw Failure(message: "No generation") }
        let oldB = try await b.read(entity)
        _ = try await a.edit(.init(base: first, changes: [.generationEdit(component: .transcript, generation: generation.id, key: "s", value: .text("Alice"))]))
        _ = try await b.edit(.init(base: oldB, changes: [.generationEdit(component: .transcript, generation: generation.id, key: "s", value: .text("Bob"))]))
        try deliver(right, to: left, writer: b.writerID)
        let model = SharedLibraryReviewState()
        await model.refresh(using: a)
        try expect(model.items.count == 1, "Review must show the real competing speaker edits")
        let item = model.items[0]
        guard let field = item.fields.first, let alice = field.choices.first(where: { $0.value == .text("Alice") }) else { throw Failure(message: "Missing readable choices") }
        try expect(field.title == "Speaker name", "Do not show internal field keys")
        try expect(alice.detail.contains("Alice"), "Show the actual alternative")
        try expect(alice.detail.contains("From: This Mac") && field.choices.first { $0.value == .text("Bob") }?.detail.contains("From: Second test Mac") == true, "Speaker choices attribute their actual source Macs")
        _ = try await a.edit(.init(base: try await a.read(entity), changes: [.assign(field: "metadata.mode", value: .text("\"Mee\""))]))
        await model.refresh(using: a)
        try expect(model.items[0].reviewSignature == item.reviewSignature, "Unrelated metadata must not reset reviewed choices")
        // A newly reviewed remote resolution must not be consumed by the old UI.
        try deliver(left, to: right, writer: a.writerID)
        _ = try await b.resolve(.init(base: try await b.read(entity), changes: [.generationEdit(component: .transcript, generation: generation.id, key: "s", value: .text("Charlie"))]))
        try deliver(right, to: left, writer: b.writerID)
        let stale = await model.apply(item: item, selections: [field.id: alice.id], using: a)
        try expect(!stale && model.message?.contains("changed") == true, "Old choice must request a fresh review")
        let current = try await a.read(entity)
        try expect(current.state.generationEdits(for: .transcript)["s"] == .text("Charlie"), "Unseen choice survives")
        // Create another true offline conflict, then resolve it from the review.
        let aBase = try await a.read(entity), bBase = try await b.read(entity)
        _ = try await a.edit(.init(base: aBase, changes: [.generationEdit(component: .transcript, generation: generation.id, key: "s", value: .text("Dana"))]))
        _ = try await b.edit(.init(base: bBase, changes: [.generationEdit(component: .transcript, generation: generation.id, key: "s", value: .text("Eli"))]))
        try deliver(right, to: left, writer: b.writerID)
        await model.refresh(using: a)
        let fresh = model.items[0], name = fresh.fields[0]
        guard let dana = name.choices.first(where: { $0.value == .text("Dana") }) else { throw Failure(message: "No Dana") }
        try expect(await model.apply(item: fresh, selections: [name.id: dana.id], using: a), "Reviewed choice must persist")
        let published = try Data(contentsOf: left.appendingPathComponent("Meeting.transcript.json"))
        try expect(String(decoding: published, as: UTF8.self).contains("Dana"), "Actual sidecar must reflect review")
        // Competing full generations render content rather than JSON/IDs.
        try deliver(left, to: right, writer: a.writerID)
        let generationBaseA = try await a.read(entity), generationBaseB = try await b.read(entity)
        let textA = Transcript(recordingFilename: "Meeting.mp3", createdAt: Date(timeIntervalSince1970: 100), transcriptionModel: "Model A", hasSpeakerLabels: false,
            segments: [.init(startTime: 0, endTime: 1, text: "Version A content")])
        let textB = Transcript(recordingFilename: "Meeting.mp3", createdAt: Date(timeIntervalSince1970: 200), transcriptionModel: "Model B", hasSpeakerLabels: false,
            segments: [.init(startTime: 0, endTime: 1, text: "Version B content")])
        let documentA = try SharedDocument(id: UUID(), json: JSONEncoder().encode(textA))
        let documentB = try SharedDocument(id: UUID(), json: JSONEncoder().encode(textB))
        _ = try await a.edit(.init(base: generationBaseA, changes: [.generation(documentA, component: .transcript)]))
        _ = try await b.edit(.init(base: generationBaseB, changes: [.generation(documentB, component: .transcript)]))
        try deliver(right, to: left, writer: b.writerID)
        await model.refresh(using: a)
        let versions = model.items.first { $0.id == entity.id }!
        let content = versions.fields.first { $0.id == "transcript.content" }!
        let optionA = content.choices.first { $0.value == .document(documentA) }!
        try expect(optionA.detail.contains("From: This Mac") && content.choices.first { $0.value == .document(documentB) }?.detail.contains("From: Second test Mac") == true, "Generation choices identify their source Macs")
        try expect(optionA.detail.contains("Version A content") && optionA.isAvailable, "Typed transcript preview must show actual content")
        try expect(await model.apply(item: versions, selections: [content.id: optionA.id], using: a), "Generation review must resolve")
        // Older edits have an explicit discard decision; never apply them to a new version.
        let currentA = try await a.read(entity)
        _ = try await b.resolve(.init(base: try await b.read(entity), changes: [.generationEdit(component: .transcript, generation: documentB.id, key: "s", value: .text("Older speaker edit"))]))
        try deliver(right, to: left, writer: b.writerID)
        await model.refresh(using: a)
        let older = model.items.first { $0.id == entity.id }!
        let oldField = older.fields.first { $0.isOlderEdits }!
        try expect(oldField.choices.first?.detail.contains("From: Second test Mac\nOlder speaker edit") == true, "Retained older edits identify their source")
        try expect(oldField.choices.first?.detail.contains("Older speaker edit") == true, "Show exactly which old edits are discarded")
        try expect(await model.apply(item: older, selections: [oldField.id: oldField.choices[0].id], using: a), "Discard older-generation edits explicitly")
        try expect((try await a.read(entity)).state.currentDocument(for: .transcript)?.id == currentA.state.currentDocument(for: .transcript)?.id, "Discard must retain current generation")
        // Summary checkboxes show their task text and resolve through generation IDs.
        try deliver(left, to: right, writer: a.writerID)
        let taskID = UUID()
        let summary = Summary(recordingFilename: "Meeting.mp3", model: "Synthetic", provider: "fixture", templateUsed: "meeting",
            sections: [.init(heading: "Tasks", content: "Summary", items: [.init(id: taskID, text: "Send meeting notes", isCompleted: false)])])
        let summaryDocument = try SharedDocument(id: UUID(), json: JSONEncoder().encode(summary))
        _ = try await a.edit(.init(base: try await a.read(entity), changes: [.generation(summaryDocument, component: .summary)]))
        try deliver(left, to: right, writer: a.writerID)
        let checkA = try await a.read(entity), checkB = try await b.read(entity)
        _ = try await a.edit(.init(base: checkA, changes: [.generationEdit(component: .summary, generation: summaryDocument.id, key: taskID.uuidString.lowercased(), value: .flag(true))]))
        _ = try await b.edit(.init(base: checkB, changes: [.generationEdit(component: .summary, generation: summaryDocument.id, key: taskID.uuidString.lowercased(), value: .flag(false))]))
        try deliver(right, to: left, writer: b.writerID)
        await model.refresh(using: a)
        let checks = model.items.first { $0.id == entity.id }!, check = model.items.first { $0.id == entity.id }!.fields[0]
        try expect(check.title.contains("Send meeting notes"), "Checklist conflict must identify its task")
        let completed = check.choices.first { $0.value == .flag(true) }!
        try expect(completed.detail.contains("From: This Mac") && check.choices.first { $0.value == .flag(false) }?.detail.contains("From: Second test Mac") == true, "Checklist choices identify their actual source Macs")
        try expect(await model.apply(item: checks, selections: [check.id: completed.id], using: a), "Reviewed checklist status must persist")
        // Template prompts use the same captured-context transaction.
        let templates = TemplateStore(baseDirectory: left, shared: SharedTemplateAdapter(coordinator: a))
        try await templates.load()
        try await templates.addUserTemplate(.init(id: "review-template", name: "Review template", description: "Fixture", promptText: "Initial prompt", isBuiltIn: false))
        _ = try await a.projectOutputs()
        try deliver(left, to: right, writer: a.writerID)
        let templateView = try await a.snapshots(kinds: [.template]).first { $0.state.value(for: "templateID") == .text("review-template") }!
        let templateEntity = SharedEntityIdentity(id: templateView.state.id, kind: .template)
        let templateB = try await b.read(templateEntity)
        _ = try await a.edit(.init(base: templateView, changes: [.assign(field: "prompt", value: .text("Prompt A"))]))
        _ = try await b.edit(.init(base: templateB, changes: [.assign(field: "prompt", value: .text("Prompt B"))]))
        try deliver(right, to: left, writer: b.writerID)
        await model.refresh(using: a)
        let templateItem = model.items.first { $0.id == templateEntity.id }!, prompt = model.items.first { $0.id == templateEntity.id }!.fields[0]
        let selectedPrompt = prompt.choices.first { $0.value == .text("Prompt B") }!
        try expect(selectedPrompt.detail.contains("From: Second test Mac"), "Template scalar choices identify the source Mac")
        try expect(await model.apply(item: templateItem, selections: [prompt.id: selectedPrompt.id], using: a), "Template review must persist")
        try await templates.load()
        try expect(await templates.template(forID: "review-template")?.promptText == "Prompt B", "Actual template adapter must reload the reviewed prompt")
        // Settings drafts retain the exact displayed context through refresh.
        let editor = TemplateEditingState()
        await editor.select(id: "review-template", using: templates)
        editor.change { $0.name = "Unsaved template name" }
        let otherTemplates = TemplateStore(baseDirectory: left, shared: SharedTemplateAdapter(coordinator: a))
        try await otherTemplates.load()
        var remoteTemplate = await otherTemplates.template(forID: "review-template")!
        remoteTemplate.promptText = "Remote prompt during draft"
        try await otherTemplates.update(remoteTemplate)
        try await templates.load()
        await editor.select(id: "review-template", using: templates)
        try expect(editor.template?.name == "Unsaved template name" && editor.hasChanges, "External refresh must retain unsaved draft")
        try expect(await editor.save(using: templates), "Independent remote field must merge with draft")
        try expect(editor.template?.promptText == "Remote prompt during draft" && !editor.hasChanges, "Accepted baseline includes independent remote changes")
        editor.change { $0.promptText = "Keep my unsaved prompt" }
        try await otherTemplates.load()
        remoteTemplate = await otherTemplates.template(forID: "review-template")!
        remoteTemplate.promptText = "New unseen remote prompt"
        try await otherTemplates.update(remoteTemplate)
        try await templates.load()
        await editor.select(id: "review-template", using: templates)
        try expect(!(await editor.save(using: templates)), "Unseen competing prompt must reject")
        try expect(editor.template?.promptText == "Keep my unsaved prompt" && editor.hasChanges && editor.message != nil, "Failure must retain draft and explain review")
        await editor.compareLatest(using: templates)
        try expect(editor.comparison?.latest.template.promptText == "New unseen remote prompt", "Comparison shows the actual new version without dropping draft")
        editor.change { $0.description = "Typed while comparing" }
        editor.acceptComparison(keepingEdits: true)
        try expect(editor.comparison == nil && editor.hasChanges, "A changed draft invalidates its earlier comparison")
        await editor.compareLatest(using: templates)
        editor.acceptComparison(keepingEdits: true)
        try await otherTemplates.load()
        remoteTemplate = await otherTemplates.template(forID: "review-template")!
        remoteTemplate.promptText = "Arrived after comparison"
        try await otherTemplates.update(remoteTemplate)
        try expect(!(await editor.save(using: templates)), "A review cannot consume a later unseen change")
        await editor.compareLatest(using: templates)
        editor.acceptComparison(keepingEdits: true)
        try expect(await editor.save(using: templates), "An explicit fresh comparison permits keeping the draft")
        try expect(editor.template?.promptText == "Keep my unsaved prompt" && editor.template?.description == "Typed while comparing", "Keep only explicitly edited fields")
        editor.change { $0.name = "Another unsaved name" }
        await editor.compareLatest(using: templates)
        editor.acceptComparison(keepingEdits: false)
        try expect(!editor.hasChanges && editor.template?.name == "Unsaved template name", "Use Latest explicitly discards the draft")
        editor.change { $0.promptText = "Keep my unsaved prompt" + " after selecting another template" }
        await editor.select(id: "meeting", using: templates)
        await editor.select(id: "review-template", using: templates)
        try expect(editor.template?.promptText == "Keep my unsaved prompt after selecting another template", "Switching templates must preserve unsaved draft")
        let anotherStore = TemplateStore(baseDirectory: right, shared: SharedTemplateAdapter(coordinator: b))
        try await anotherStore.load()
        await editor.select(id: "meeting", using: anotherStore)
        try expect(editor.template?.id == "meeting" && !editor.hasChanges, "A library switch cannot apply old drafts to a new store")
        let pause = SavePause()
        let pausedCoordinator = SharedLibraryCoordinator(root: left, writerID: a.writerID, witnessDirectory: parent.appendingPathComponent("a-local"), afterCommit: { await pause.pauseOnce() })
        let pausedStore = TemplateStore(baseDirectory: left, shared: SharedTemplateAdapter(coordinator: pausedCoordinator))
        try await pausedStore.load()
        let typing = TemplateEditingState()
        await typing.select(id: "review-template", using: pausedStore)
        typing.change { $0.description = "Accepted description" }
        let saving = Task { await typing.save(using: pausedStore) }
        for _ in 0..<500 {
            if await pause.entered { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try expect(await pause.entered, "Save must reach its actual accepted commit")
        typing.change { $0.description = "New typing during save" }
        await pause.release()
        try expect(await saving.value, "Accepted save succeeds")
        try expect(typing.template?.description == "New typing during save" && typing.hasChanges, "An in-flight completion cannot erase later typing")
        try expect(await typing.save(using: pausedStore) && !typing.hasChanges, "Later typing saves against the accepted context")
        await typing.select(id: "meeting", using: pausedStore)
        typing.change { $0.promptText = "Custom built-in override" }
        try expect(await typing.save(using: pausedStore), "Built-in draft override saves")
        try expect(await typing.reset(id: "meeting", using: pausedStore), "Native reset uses reviewed context")
        try expect(typing.template == TemplateStore.builtInDefaults[0] && !typing.hasChanges, "Native reset returns to a clean default baseline")
        let recoveryRoot = parent.appendingPathComponent("recovery")
        try FileManager.default.createDirectory(at: recoveryRoot, withIntermediateDirectories: true)
        try Data("disposable recovery audio".utf8).write(to: recoveryRoot.appendingPathComponent("Recovery.mp3"))
        let recovery = SharedLibraryCoordinator(root: recoveryRoot, writerID: UUID(), witnessDirectory: parent.appendingPathComponent("recovery-local"), trash: { url in
            let recycled = parent.appendingPathComponent("recovery-disposed")
            try FileManager.default.createDirectory(at: recycled, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: recycled.appendingPathComponent(url.lastPathComponent))
        })
        _ = try await recovery.enable(); _ = try await recovery.projectOutputs()
        do { _ = try await recovery.relocateRecording(filename: "Recovery.mp3", title: "Recovered", afterMutation: { _ in throw Failure(message: "simulated interruption") }) }
        catch let failure as Failure { try expect(failure.message == "simulated interruption", "Expected physical interruption") }
        let files = RecordingFileReviewState()
        await files.refresh(using: recovery)
        try expect(files.items.count == 1 && files.items[0].canResume, "Actual pending file review shows resumable recording")
        try expect(await files.perform(.resume, review: files.items[0], using: recovery), "Native action resumes the reviewed plan")
        try expect(files.items.isEmpty && FileManager.default.fileExists(atPath: recoveryRoot.appendingPathComponent("Recovered.mp3").path), "Completion clears pending row")
        let updatedRoot = parent.appendingPathComponent("updated-recovery")
        try FileManager.default.createDirectory(at: updatedRoot, withIntermediateDirectories: true)
        try Data("updated plan synthetic original".utf8).write(to: updatedRoot.appendingPathComponent("Start.mp3"))
        let updatedCoordinator = SharedLibraryCoordinator(root: updatedRoot, writerID: UUID(), witnessDirectory: parent.appendingPathComponent("updated-recovery-local"))
        _ = try await updatedCoordinator.enable(); _ = try await updatedCoordinator.projectOutputs()
        let updatedID = try await updatedCoordinator.reference(to: "Start.mp3").entityID
        do { _ = try await updatedCoordinator.relocateRecording(filename: "Start.mp3", title: "Intermediate", afterMutation: { _ in throw Failure(message: "partial updated plan") }) }
        catch let failure as Failure { try expect(failure.message == "partial updated plan", "Expected actual move interruption") }
        _ = try await updatedCoordinator.edit(.init(base: try await updatedCoordinator.read(.init(id: updatedID, kind: .recording)), changes: [.assign(field: "title", value: .text("Final"))]))
        let updates = RecordingFileReviewState()
        await updates.refresh(using: updatedCoordinator)
        try expect(updates.items.count == 1 && updates.items[0].needsReplanning, "Changed destination appears in pending files")
        await updates.prepareUpdatedPlan(updates.items[0], using: updatedCoordinator)
        try expect(updates.updatedPlan?.destination == "Final.mp3" && updates.updatedPlan?.sources == ["Intermediate.mp3"], "Native preview shows actual original and intended destination")
        try expect(await updates.applyUpdatedPlan(using: updatedCoordinator), "Native action applies only its prepared review")
        try expect(updates.updatedPlan == nil && updates.items.isEmpty && FileManager.default.fileExists(atPath: updatedRoot.appendingPathComponent("Final.mp3").path), "Updated plan completes and clears review")
        do { _ = try await updatedCoordinator.relocateRecording(filename: "Final.mp3", title: "Next", afterMutation: { _ in throw Failure(message: "second interrupted plan") }) }
        catch let failure as Failure { try expect(failure.message == "second interrupted plan", "Expected second actual interruption") }
        _ = try await updatedCoordinator.edit(.init(base: try await updatedCoordinator.read(.init(id: updatedID, kind: .recording)), changes: [.assign(field: "title", value: .text("Selected"))]))
        await updates.refresh(using: updatedCoordinator)
        await updates.prepareUpdatedPlan(updates.items[0], using: updatedCoordinator)
        _ = try await updatedCoordinator.edit(.init(base: try await updatedCoordinator.read(.init(id: updatedID, kind: .recording)), changes: [.assign(field: "title", value: .text("Newer"))]))
        try expect(!(await updates.applyUpdatedPlan(using: updatedCoordinator)), "Stale native preview cannot apply a newer edit")
        try expect(updates.updatedPlan == nil && updates.items.count == 1 && updates.items[0].title == "Newer", "Failed native action reloads current review and drops stale preview")
        try expect(FileManager.default.fileExists(atPath: updatedRoot.appendingPathComponent("Next.mp3").path) && !FileManager.default.fileExists(atPath: updatedRoot.appendingPathComponent("Selected.mp3").path), "Stale preview preserves the actual source")
        let peerRoot = parent.appendingPathComponent("recovery-peer")
        try FileManager.default.copyItem(at: recoveryRoot, to: peerRoot)
        let peer = SharedLibraryCoordinator(root: peerRoot, writerID: UUID(), witnessDirectory: parent.appendingPathComponent("recovery-peer-local"))
        try await peer.requestEnrollment(requestID: UUID(), label: "Recovery peer")
        for _ in 0..<3 {
            try deliver(peerRoot, to: recoveryRoot, writer: peer.writerID); try await recovery.refresh()
            try deliver(recoveryRoot, to: peerRoot, writer: recovery.writerID); try await peer.refresh()
        }
        _ = try await recovery.deleteSharedRecording(filename: "Recovered.mp3")
        await files.refresh(using: recovery)
        try expect(files.items.first?.waitingForMacs == ["Recovery peer"], "Show the actual participating Mac still needed")
        try deliver(recoveryRoot, to: peerRoot, writer: recovery.writerID)
        let peerFiles = RecordingFileReviewState()
        await peerFiles.refresh(using: peer)
        try expect(peerFiles.items.count == 1 && peerFiles.items[0].canAcknowledge, "Peer can review creator's deletion without a copied local receipt")
        try expect(await peerFiles.perform(.acknowledge, review: peerFiles.items[0], using: peer), "Peer explicitly approves its reviewed revision")
        try deliver(peerRoot, to: recoveryRoot, writer: peer.writerID)
        await files.refresh(using: recovery)
        try expect(files.items.first?.canResume == true, "Owner resumes after exact cohort acknowledgment arrives")
        try expect(await files.perform(.resume, review: files.items[0], using: recovery), "Owner disposes only synthetic fixture")
        try deliver(recoveryRoot, to: peerRoot, writer: recovery.writerID)
        // Metadata arrives before the provider's physical deletion.
        let libraryBytes = try Data(contentsOf: recoveryRoot.appendingPathComponent("library.json"))
        try libraryBytes.write(to: peerRoot.appendingPathComponent("library.json"), options: .atomic)
        await peerFiles.refresh(using: peer)
        try expect(peerFiles.items.count == 1 && FileManager.default.fileExists(atPath: peerRoot.appendingPathComponent("Recovered.mp3").path), "Metadata arrival alone cannot claim local deletion completed")
        try FileManager.default.removeItem(at: peerRoot.appendingPathComponent("Recovered.mp3")) // Simulated late provider removal, disposable data only.
        let lateCompanion = peerRoot.appendingPathComponent("Recovered.summary.md")
        let lateBytes = Data("late provider companion, not approved for removal".utf8)
        try lateBytes.write(to: lateCompanion)
        await peerFiles.refresh(using: peer)
        try expect(peerFiles.items.count == 1 && (try Data(contentsOf: lateCompanion)) == lateBytes, "A late unplanned companion keeps cleanup visible and unchanged")
        try FileManager.default.removeItem(at: lateCompanion)
        let latePlaceholder = peerRoot.appendingPathComponent(".Recovered.summary.md.icloud")
        try Data().write(to: latePlaceholder)
        await peerFiles.refresh(using: peer)
        try expect(peerFiles.items.count == 1, "A late companion placeholder cannot be mistaken for completed removal")
        try FileManager.default.removeItem(at: latePlaceholder)
        await peerFiles.refresh(using: peer)
        try expect(peerFiles.items.isEmpty, "Exact acknowledged absence clears the mirrored pending row")
        let mirrored = try await peer.resumeRecordingOperation(id: try await peer.snapshots(kinds: [.recording])[0].state.id)
        try expect(mirrored.result == .complete, "Exact mirrored completion must also be resumable without claiming local Trash work")
        let peerViews = try await peer.snapshots(kinds: [.recording])
        guard let peerRecording = peerViews.first else { throw Failure(message: "Missing peer fixture") }
        let brokenHead = peerRoot.appendingPathComponent(".docktape/records/" + peerRecording.state.id.uuidString.lowercased() + "/" + recovery.writerID.uuidString.lowercased() + ".json")
        try Data("unreadable pending metadata fixture".utf8).write(to: brokenHead, options: .atomic)
        await peerFiles.refresh(using: peer)
        try expect(peerFiles.inspectionFailed && peerFiles.message != nil, "A failed inspection cannot claim an empty clean pending list")
        peerFiles.clear()
        files.clear()
        try expect(files.items.isEmpty && files.message == nil, "Library switch clears operation review")
        model.clear()
        try expect(model.items.isEmpty && model.message == nil, "Library switching clears old review")
        if ui {
            try deliver(left, to: right, writer: a.writerID)
            let nativeTranscript = Transcript(recordingFilename: "Meeting.mp3", transcriptionModel: "Synthetic", hasSpeakerLabels: true,
                segments: [.init(startTime: 0, endTime: 1, text: "Synthetic review conversation", speakerID: "s")])
            let nativeDocument = try SharedDocument(id: UUID(), json: JSONEncoder().encode(nativeTranscript))
            _ = try await a.edit(.init(base: try await a.read(entity), changes: [.generation(nativeDocument, component: .transcript)]))
            try deliver(left, to: right, writer: a.writerID)
            let firstNative = try await a.read(entity), secondNative = try await b.read(entity)
            _ = try await a.edit(.init(base: firstNative, changes: [.generationEdit(component: .transcript, generation: nativeDocument.id, key: "s", value: .text("Native Alice"))]))
            _ = try await b.edit(.init(base: secondNative, changes: [.generationEdit(component: .transcript, generation: nativeDocument.id, key: "s", value: .text("Native Bob"))]))
            try deliver(right, to: left, writer: b.writerID)
            UserDefaults.standard.setVolatileDomain(["storageMode": "local"], forName: UserDefaults.argumentDomain)
            let state = AppState(baseDirectory: left, sharedIdentity: {
                try await SharedLibraryWriterIdentityStore(file: identityFile, installationAnchor: "synthetic review installation").load()
            }, sharedWitnessDirectory: parent.appendingPathComponent("a-local"))
            try await state.setup()
            NSApp.setActivationPolicy(.regular)
            NSApp.mainMenu = MainMenu.build(appState: state)
            let host = MainWindowController(appState: state)
            host.showWindow(nil); host.showSharedLibraryReview(nil)
            NSApp.activate()
            qaWindow = host
        }
        print("Actual shared review passed: real two-root speaker/generation/older-edit/checklist/template conflicts, readable alternatives, stale refusal, publication, retained drafts, explicit comparisons, accepted-save typing, reviewed Resume/approval, metadata-first peer deletion and binding reset.")
    }
}
