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
