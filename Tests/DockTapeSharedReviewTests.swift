// © 2026 High Gain Design. All rights reserved.
import AppKit
import HiDockKit

@main struct DockTapeSharedReviewTests {
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
        try expect(optionA.detail.contains("Version A content") && optionA.isAvailable, "Typed transcript preview must show actual content")
        try expect(await model.apply(item: versions, selections: [content.id: optionA.id], using: a), "Generation review must resolve")
        // Older edits have an explicit discard decision; never apply them to a new version.
        let currentA = try await a.read(entity)
        _ = try await b.resolve(.init(base: try await b.read(entity), changes: [.generationEdit(component: .transcript, generation: documentB.id, key: "s", value: .text("Older speaker edit"))]))
        try deliver(right, to: left, writer: b.writerID)
        await model.refresh(using: a)
        let older = model.items.first { $0.id == entity.id }!
        let oldField = older.fields.first { $0.isOlderEdits }!
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
        await peerFiles.refresh(using: peer)
        try expect(peerFiles.items.isEmpty, "Exact acknowledged absence clears the mirrored pending row")
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
