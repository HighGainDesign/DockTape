// © 2026 High Gain Design. All rights reserved.
import XCTest
@testable import HiDockKit

final class SharedLibraryProjectionWriterTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() { for root in roots { try? FileManager.default.removeItem(at: root) } }
    private func fixture(additionalAudio: [String] = []) async throws -> (URL, SharedLibraryCoordinator) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        roots.append(directory)
        let root = directory.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("synthetic".utf8).write(to: root.appendingPathComponent("Meeting.mp3"))
        for path in additionalAudio {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("unrelated synthetic original".utf8).write(to: url)
        }
        let recording = RecordingStore(baseDirectory: root)
        try await recording.setup()
        try await recording.setMeta(mode: "Rec", deviceFilename: "device.hda", for: "Meeting.mp3")
        let transcript = Transcript(recordingFilename: "Meeting.mp3", transcriptionModel: "fixture", hasSpeakerLabels: true,
            segments: [.init(startTime: 0, endTime: 1, text: "Readable fixture", speakerID: "s")])
        try await TranscriptStore(baseDirectory: root).save(transcript, mp3Filename: "Meeting.mp3")
        var template = TemplateStore.builtInDefaults[0]; template.promptText = "Fixture prompt"
        try await TemplateStore(baseDirectory: root).update(template)
        let coordinator = SharedLibraryCoordinator(root: root, writerID: UUID(), witnessDirectory: directory.appendingPathComponent("local"))
        _ = try await coordinator.enable()
        return (root, coordinator)
    }
    func testInterruptedBootstrapAggregateHasExplicitRecovery() async throws {
        struct Interrupted: Error {}
        for output in [1, 5] {
            let (root, coordinator) = try await fixture()
            do {
                _ = try await coordinator.projectOutputs(beforeOutput: { index in
                    if index == output { throw Interrupted() }
                })
                XCTFail("Expected interruption")
            } catch is Interrupted {}
            let path = output == 1 ? ".templates.json" : "library.json"
            do { _ = try await coordinator.projectOutputs(); XCTFail("Ordinary replay must require new consent") }
            catch SharedProjectionWriteError.untracked(let blocked) { XCTAssertEqual(blocked, path) }
            let reviews = try await coordinator.reviewBootstrapProjections()
            let review = try XCTUnwrap(reviews.first(where: { $0.filename == path }))
            _ = try await coordinator.restoreBootstrapProjection(review)
            _ = try await coordinator.projectOutputs()
            let settled = try await coordinator.projectOutputs()
            XCTAssertEqual(settled.written, 0)
            XCTAssertNotNil(try SharedProjectionDocument.marker(in: Data(contentsOf: root.appendingPathComponent("library.json"))))
        }
    }

    func testBootstrapReviewCannotReplayConsentForReappearedBytes() async throws {
        let (root, coordinator) = try await fixture()
        let url = root.appendingPathComponent(".templates.json")
        let original = try Data(contentsOf: url)
        _ = try await coordinator.projectOutputs()
        try original.write(to: url)
        let reviews = try await coordinator.reviewBootstrapProjections()
        let review = try XCTUnwrap(reviews.first(where: { $0.filename == ".templates.json" }))
        _ = try await coordinator.restoreBootstrapProjection(review)
        try original.write(to: url)
        do { _ = try await coordinator.restoreBootstrapProjection(review); XCTFail("Consumed review must not authorize a later occurrence") }
        catch SharedLibraryCoordinatorError.staleReview {}
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testInterruptedBootstrapSidecarCanBeReviewedBeforeLibraryPublication() async throws {
        let (root, coordinator) = try await fixture()
        let url = root.appendingPathComponent("Meeting.transcript.json")
        let original = try Data(contentsOf: url)
        do { _ = try await coordinator.projectOutputs(beforeOutput: { index in if index == 2 { throw CancellationError() } }); XCTFail("Expected interruption") }
        catch is CancellationError {}
        let view = try await coordinator.recording(at: "Meeting.mp3")
        let reviews = try await coordinator.reviewSidecars(.init(id: view.state.id, kind: .recording))
        XCTAssertEqual(reviews.count, 1, "A spent bootstrap approval must be actionable even before library.json publication")
        if let review = reviews.first {
            _ = try await coordinator.recoverSidecar(review, useChangedFile: false)
            _ = try await coordinator.projectOutputs()
        }
        XCTAssertNotEqual(try Data(contentsOf: url), original)
    }

    func testTwoReappearedBootstrapAggregatesCanBeRestoredIndependently() async throws {
        let (root, coordinator) = try await fixture()
        let names = [".templates.json", "library.json"]
        let originals = try Dictionary(uniqueKeysWithValues: names.map { ($0, try Data(contentsOf: root.appendingPathComponent($0))) })
        _ = try await coordinator.projectOutputs()
        for path in names { try originals[path]!.write(to: root.appendingPathComponent(path)) }
        var reviews = try await coordinator.reviewBootstrapProjections()
        XCTAssertEqual(reviews.count, 2)
        _ = try await coordinator.restoreBootstrapProjection(XCTUnwrap(reviews.first { $0.filename == ".templates.json" }))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("library.json")), originals["library.json"])
        reviews = try await coordinator.reviewBootstrapProjections()
        _ = try await coordinator.restoreBootstrapProjection(XCTUnwrap(reviews.first { $0.filename == "library.json" }))
        let remaining = try await coordinator.reviewBootstrapProjections()
        XCTAssertTrue(remaining.isEmpty)
        _ = try await coordinator.projectOutputs()
    }

    private actor PublicationGate {
        var waiting = false
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async { waiting = true; await withCheckedContinuation { continuation = $0 } }
        func release() { continuation?.resume(); continuation = nil }
    }
    func testCleanBootstrapInspectionDoesNotRequirePublicationAuthorityDuringAnEdit() async throws {
        let (root, initial) = try await fixture()
        _ = try await initial.projectOutputs()
        let gate = PublicationGate()
        let coordinator = SharedLibraryCoordinator(root: root, writerID: initial.writerID,
            witnessDirectory: root.deletingLastPathComponent().appendingPathComponent("local"), afterCommit: { await gate.wait() })
        let view = try await coordinator.recording(at: "Meeting.mp3")
        let editing = Task { try await coordinator.edit(.init(base: view, changes: [.assign(field: "metadata.mode", value: .text("\"Mee\""))])) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await gate.waiting) {
            if ContinuousClock.now >= deadline { await gate.release(); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(10))
        }
        do {
            let reviews = try await coordinator.reviewBootstrapProjections()
            XCTAssertTrue(reviews.isEmpty, "Clean marked aggregates need no mutation authority or error row")
        } catch { await gate.release(); _ = try? await editing.value; throw error }
        await gate.release(); _ = try await editing.value
    }

    func testScopedPublicationDoesNotWaitForUnrelatedAcceptedRename() async throws {
        try await checkScopedPublicationWithPendingMove(folder: false)
    }
    func testScopedPublicationDoesNotWaitForUnrelatedAcceptedFolderRename() async throws {
        try await checkScopedPublicationWithPendingMove(folder: true)
    }
    private func checkScopedPublicationWithPendingMove(folder: Bool) async throws {
        let source = folder ? "Moving/Pending.mp3" : "Pending.mp3"
        let destination = folder ? "Moved/Pending.mp3" : "Renamed.mp3"
        let (root, coordinator) = try await fixture(additionalAudio: [source])
        _ = try await coordinator.projectOutputs()
        let pending = try await coordinator.reference(to: source)
        let cancelled = SharedLibraryCoordinator(root: root, writerID: coordinator.writerID,
            witnessDirectory: root.deletingLastPathComponent().appendingPathComponent("local"),
            afterCommit: { withUnsafeCurrentTask { $0?.cancel() } })
        let rename = Task {
            if folder { _ = try await cancelled.renameFolder(from: "Moving", to: "Moved") }
            else { _ = try await cancelled.relocateRecording(filename: source, title: "Renamed") }
        }
        do { _ = try await rename.value; XCTFail("Fixture must stop after semantic acceptance") }
        catch is CancellationError {}
        let accepted = try await coordinator.read(.init(id: pending.entityID, kind: .recording))
        if folder {
            let folders = try await coordinator.snapshots(kinds: [.folder])
            XCTAssertTrue(folders.contains { $0.state.value(for: "name") == .text("Moved") && $0.state.value(for: "physicalPath") == .text("Moving") })
        } else { XCTAssertEqual(accepted.state.value(for: "title"), .text("Renamed")) }
        let held = try Data(contentsOf: root.appendingPathComponent(source))
        let library = try Data(contentsOf: root.appendingPathComponent("library.json"))
        let store = TranscriptStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: coordinator))
        _ = try await store.loadTranscript(for: "Meeting.mp3")
        let transcript = Transcript(recordingFilename: "Meeting.mp3", transcriptionModel: "fixture", hasSpeakerLabels: true,
            segments: [.init(startTime: 0, endTime: 1, text: "Resident B remains editable", speakerID: "s")])
        try await store.save(transcript, mp3Filename: "Meeting.mp3")
        let entity = SharedEntityIdentity(id: try await coordinator.reference(to: "Meeting.mp3").entityID, kind: .recording)
        do { _ = try await coordinator.projectOutputs(); XCTFail("Full publication must still refuse unfinished relocation") }
        catch SharedLibraryOperationError.unfinishedOperation {}
        do {
            _ = try await coordinator.projectOutputs(for: .init(id: pending.entityID, kind: .recording), component: .transcript)
            XCTFail("Selected recording's own unfinished move or ancestor folder must still refuse publication")
        } catch SharedLibraryOperationError.unfinishedOperation {}
        let output = try await coordinator.projectOutputs(for: entity, component: .transcript)
        XCTAssertEqual(output.written, 3)
        for name in ["Meeting.transcript.md", "Meeting.txt"] {
            XCTAssertTrue(try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8).contains("Resident B remains editable"))
        }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(source)), held)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("library.json")), library)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(destination).path))
    }

    func testScopedContentPublicationPreservesUnrelatedExternalFilesAndUpdatesExports() async throws {
        let (root, coordinator) = try await fixture()
        let summaries = SummaryStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: coordinator))
        try await summaries.save(Summary(recordingFilename: "Meeting.mp3", model: "fixture", provider: "fixture", templateUsed: "fixture",
            sections: [.init(heading: "Summary", content: "Selected summary")]), mp3Filename: "Meeting.mp3")
        _ = try await coordinator.projectOutputs()
        let entity = SharedEntityIdentity(id: try await coordinator.recording(at: "Meeting.mp3").state.id, kind: .recording)
        let transcript = root.appendingPathComponent("Meeting.transcript.json")
        let summary = root.appendingPathComponent("Meeting.summary.json")
        let templates = root.appendingPathComponent(".templates.json")
        let library = try Data(contentsOf: root.appendingPathComponent("library.json"))
        let damaged = Data("{unrelated external file".utf8)
        try damaged.write(to: summary); try damaged.write(to: templates)
        var body = try JSONSerialization.jsonObject(with: Data(contentsOf: transcript)) as! [String: Any]
        var segments = body["segments"] as! [[String: Any]]; segments[0]["text"] = "Scoped accepted transcript"; body["segments"] = segments
        try JSONSerialization.data(withJSONObject: body).write(to: transcript)
        let reviews = try await coordinator.reviewSidecars(entity)
        _ = try await coordinator.recoverSidecar(XCTUnwrap(reviews.first { $0.component == .transcript }), useChangedFile: true)
        let written = try await coordinator.projectOutputs(for: entity, component: .transcript)
        XCTAssertEqual(written.written, 3)
        XCTAssertEqual(try Data(contentsOf: summary), damaged)
        XCTAssertEqual(try Data(contentsOf: templates), damaged)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("library.json")), library)
        for path in ["Meeting.transcript.md", "Meeting.txt"] { XCTAssertTrue(try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8).contains("Scoped accepted transcript")) }
        let transcriptBytes = try Data(contentsOf: transcript)
        let next = try await coordinator.reviewSidecars(entity)
        _ = try await coordinator.recoverSidecar(XCTUnwrap(next.first { $0.component == .summary }), useChangedFile: false)
        let restored = try await coordinator.projectOutputs(for: entity, component: .summary)
        XCTAssertEqual(restored.written, 2)
        XCTAssertEqual(try Data(contentsOf: transcript), transcriptBytes)
        XCTAssertEqual(try Data(contentsOf: templates), damaged)
        XCTAssertTrue(try String(contentsOf: root.appendingPathComponent("Meeting.summary.md"), encoding: .utf8).contains("Selected summary"))
        let remaining = try await coordinator.reviewSidecars(entity)
        XCTAssertTrue(remaining.isEmpty)
    }
    func testScopedPublicationRejectsMissingContentWithoutTouchingOutputs() async throws {
        let (root, coordinator) = try await fixture()
        _ = try await coordinator.projectOutputs()
        let before = try Data(contentsOf: root.appendingPathComponent("library.json"))
        let entity = SharedEntityIdentity(id: try await coordinator.recording(at: "Meeting.mp3").state.id, kind: .recording)
        do { _ = try await coordinator.projectOutputs(for: entity, component: .summary); XCTFail("No summary is not a successful summary publication") }
        catch SharedSidecarError.invalidContent {}
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("library.json")), before)
    }

    func testFirstProjectionWithExplicitPrivateTmpRootAcceptsItsCoordinatedDirectory() async throws {
        let requested = URL(fileURLWithPath: "/private/tmp/DockTapeProjectionAlias-" + UUID().uuidString + "/data")
        roots.append(requested.deletingLastPathComponent())
        try FileManager.default.createDirectory(at: requested, withIntermediateDirectories: true)
        let parent = requested.standardizedFileURL.resolvingSymlinksInPath()
        let root = parent.appendingPathComponent("left")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("synthetic".utf8).write(to: root.appendingPathComponent("Meeting.mp3"))
        let coordinator = SharedLibraryCoordinator(root: root, writerID: UUID(), witnessDirectory: parent.appendingPathComponent("new-local"))
        _ = try await coordinator.enable()
        let result = try await coordinator.projectOutputs()
        XCTAssertGreaterThan(result.written, 0)
        let next = try await coordinator.projectOutputs()
        XCTAssertEqual(next.written, 0)
    }
    private actor ReadStage {
        private var count = 0
        func first() -> Bool { count += 1; return count == 1 }
        func observations() -> Int { count }
    }
    func testPublishedLocationsReadRetriesWhenKnownProjectionAdvancesBetweenFiles() async throws {
        let (root, coordinator) = try await fixture()
        _ = try await coordinator.projectOutputs()
        let view = try await coordinator.recording(at: "Meeting.mp3")
        let permission = try await coordinator.operationAuthority(entity: .init(id: view.state.id, kind: .recording), paths: [])
        let manifest = try JSONDecoder().decode(SharedBootstrapManifest.self, from: Data(contentsOf: root.appendingPathComponent(".docktape/format.json")))
        let stage = ReadStage()
        let locations = try await SharedPublishedLocations.load(root: root, manifest: manifest, membership: permission.membership, afterLibraryRead: {
            if await stage.first() {
                let current = try await coordinator.read(.init(id: view.state.id, kind: .recording))
                _ = try await coordinator.edit(.init(base: current, changes: [.assign(field: "metadata.mode", value: .text("\"Mee\""))]))
                _ = try await coordinator.projectOutputs()
            }
        })
        let library = root.appendingPathComponent("library.json")
        XCTAssertEqual(locations.proofs[library], SharedLibraryOperation.fingerprint(try Data(contentsOf: library)))
        XCTAssertEqual(locations.recordings[view.state.id], ["Meeting.mp3"])
    }
    func testPublishedLocationsReadStillRefusesStableExternalLibraryAfterRace() async throws {
        let (root, coordinator) = try await fixture()
        _ = try await coordinator.projectOutputs()
        let view = try await coordinator.recording(at: "Meeting.mp3")
        let permission = try await coordinator.operationAuthority(entity: .init(id: view.state.id, kind: .recording), paths: [])
        let manifest = try JSONDecoder().decode(SharedBootstrapManifest.self, from: Data(contentsOf: root.appendingPathComponent(".docktape/format.json")))
        let external = Data("{\"External.mp3\":{\"mode\":\"Rec\"}}".utf8)
        let stage = ReadStage()
        do {
            _ = try await SharedPublishedLocations.load(root: root, manifest: manifest, membership: permission.membership, afterLibraryRead: {
                if await stage.first() { try external.write(to: root.appendingPathComponent("library.json"), options: .atomic) }
            })
            XCTFail("A retry must not adopt an unmarked external library")
        } catch SharedProjectionWriteError.untracked(let path) { XCTAssertEqual(path, "library.json") }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("library.json")), external)
    }
    func testPublishedLocationsReadBoundsRetriesWhenEveryProjectionChanges() async throws {
        let (root, coordinator) = try await fixture()
        _ = try await coordinator.projectOutputs()
        let view = try await coordinator.recording(at: "Meeting.mp3")
        let permission = try await coordinator.operationAuthority(entity: .init(id: view.state.id, kind: .recording), paths: [])
        let manifest = try JSONDecoder().decode(SharedBootstrapManifest.self, from: Data(contentsOf: root.appendingPathComponent(".docktape/format.json")))
        let stage = ReadStage()
        do {
            _ = try await SharedPublishedLocations.load(root: root, manifest: manifest, membership: permission.membership, afterLibraryRead: {
                _ = await stage.first()
                let current = try await coordinator.read(.init(id: view.state.id, kind: .recording))
                _ = try await coordinator.edit(.init(base: current, changes: [.assign(field: "metadata.mode", value: .text("\"Mee\""))]))
                _ = try await coordinator.projectOutputs()
            })
            XCTFail("Continuously changing input must not yield a mixed snapshot")
        } catch SharedProjectionWriteError.stale {}
        let attempts = await stage.observations()
        XCTAssertEqual(attempts, 3)
    }
    func testWritesCanonicalAggregatesAndReadableFilesThenSkipsIdenticalBytes() async throws {
        let (root, coordinator) = try await fixture()
        let records = RecordingStore(baseDirectory: root, shared: SharedRecordingMetadataAdapter(coordinator: coordinator))
        try await records.setup()
        try await records.setMeta(mode: "Mee", deviceFilename: "device.hda", for: "Meeting.mp3")
        let transcripts = TranscriptStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: coordinator))
        _ = try await transcripts.loadTranscript(for: "Meeting.mp3")
        try await transcripts.updateSpeakerNames(for: "Meeting.mp3", names: ["s": "Alice"])
        let first = try await coordinator.projectOutputs()
        XCTAssertGreaterThan(first.written, 0)
        let library = try Data(contentsOf: root.appendingPathComponent("library.json"))
        let meta = try JSONDecoder().decode([String: RecordingStore.RecordingMeta].self, from: library)
        XCTAssertEqual(meta["Meeting.mp3"]?.mode, "Mee")
        XCTAssertNotNil(try SharedProjectionDocument.marker(in: library))
        XCTAssertTrue(String(decoding: try Data(contentsOf: root.appendingPathComponent("Meeting.transcript.md")), as: UTF8.self).contains("Alice"))
        let templateBytes = try Data(contentsOf: root.appendingPathComponent(".templates.json"))
        XCTAssertNotNil(try SharedProjectionDocument.marker(in: templateBytes))
        let before = try root.appendingPathComponent("Meeting.transcript.md").resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let next = try await coordinator.projectOutputs()
        XCTAssertEqual(next.written, 0)
        let after = try root.appendingPathComponent("Meeting.transcript.md").resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        XCTAssertEqual(before, after)
    }
    func testUntrackedJSONEditRemainsUntouchedDuringProjection() async throws {
        let (root, coordinator) = try await fixture()
        _ = try await coordinator.projectOutputs()
        let file = root.appendingPathComponent("Meeting.transcript.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        object["speakerNames"] = ["s": "External edit"]
        let external = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try external.write(to: file, options: .atomic)
        do { _ = try await coordinator.projectOutputs(); XCTFail("Untracked changes must require adoption") }
        catch SharedProjectionWriteError.untracked("Meeting.transcript.json") {}
        XCTAssertEqual(try Data(contentsOf: file), external)
    }
    func testChangedLegacyJSONAfterEnableIsNotSilentlyOverwritten() async throws {
        let (root, coordinator) = try await fixture()
        let file = root.appendingPathComponent("library.json")
        let external = Data("{\"Meeting.mp3\":{\"mode\":\"Wip\"}}".utf8)
        try external.write(to: file, options: .atomic)
        do { _ = try await coordinator.projectOutputs(); XCTFail("Initial projection cannot consume unknown changes") }
        catch SharedProjectionWriteError.untracked("library.json") {}
        XCTAssertEqual(try Data(contentsOf: file), external)
    }
    func testWholeLibraryGuardRejectsAnUnrelatedEditBeforeAggregateWrite() async throws {
        let (root, coordinator) = try await fixture()
        let original = try Data(contentsOf: root.appendingPathComponent("library.json"))
        let templates = TemplateStore(baseDirectory: root, shared: SharedTemplateAdapter(coordinator: coordinator))
        try await templates.load()
        var changed = TemplateStore.builtInDefaults[0]; changed.promptText = "Later prompt"
        let target = changed
        do {
            _ = try await coordinator.projectOutputs(beforeWrite: { try? await templates.update(target) })
            XCTFail("Any affected library revision must invalidate the aggregate plan")
        } catch SharedProjectionWriteError.stale {}
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("library.json")), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Meeting.transcript.md").path))
    }
    private enum Interrupted: Error { case crash }
    func testPartialPublicationRecognizesBothOldAndPendingDocumentsAfterRestart() async throws {
        let (root, coordinator) = try await fixture()
        _ = try await coordinator.projectOutputs()
        let records = RecordingStore(baseDirectory: root, shared: SharedRecordingMetadataAdapter(coordinator: coordinator))
        try await records.setup()
        try await records.setMeta(mode: "Mee", deviceFilename: "device.hda", for: "Meeting.mp3")
        do {
            _ = try await coordinator.projectOutputs(afterOutput: { _ in throw Interrupted.crash })
            XCTFail("Expected interruption after a physical output")
        } catch Interrupted.crash {}
        let restarted = SharedLibraryCoordinator(root: root, writerID: coordinator.writerID,
            witnessDirectory: root.deletingLastPathComponent().appendingPathComponent("local"))
        _ = try await restarted.projectOutputs()
        let bytes = try Data(contentsOf: root.appendingPathComponent("library.json"))
        let library = try JSONDecoder().decode([String: RecordingStore.RecordingMeta].self, from: bytes)
        XCTAssertEqual(library["Meeting.mp3"]?.mode, "Mee")
        let noChanges = try await restarted.projectOutputs()
        XCTAssertEqual(noChanges.written, 0)
    }

    private func deliver(_ source: URL, _ destination: URL, writer: UUID) throws {
        let tree = source.appendingPathComponent(".docktape").resolvingSymlinksInPath()
        let iterator = try XCTUnwrap(FileManager.default.enumerator(at: tree, includingPropertiesForKeys: [.isDirectoryKey]))
        for case let file as URL in iterator {
            guard (try file.resourceValues(forKeys: [.isDirectoryKey])).isDirectory != true else { continue }
            let bytes = try Data(contentsOf: file)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            let payload = object["payload"] as? [String: Any]
            let owner = (object["writerID"] as? String) ?? (payload?["writer"] as? String) ?? (object["founder"] as? String)
            guard owner.flatMap(UUID.init(uuidString:)) == writer else { continue }
            let relative = String(file.resolvingSymlinksInPath().path.dropFirst(tree.path.count + 1))
            let target = destination.appendingPathComponent(".docktape/" + relative)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: target, options: .atomic)
        }
    }
    func testContestedGenerationsPublishTheLastConfirmedContentOnAReopenedMac() async throws {
        let (left, one) = try await fixture()
        let secondDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        roots.append(secondDirectory)
        try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        let right = secondDirectory.appendingPathComponent("library")
        try FileManager.default.copyItem(at: left, to: right)
        let two = SharedLibraryCoordinator(root: right, writerID: UUID(), witnessDirectory: secondDirectory.appendingPathComponent("local"))
        try await two.requestEnrollment(requestID: UUID(), label: "Fixture B")
        try deliver(right, left, writer: two.writerID)
        for _ in 0..<3 {
            try await one.refresh(); try deliver(left, right, writer: one.writerID)
            try await two.refresh(); try deliver(right, left, writer: two.writerID)
        }
        let a = TranscriptStore(baseDirectory: left, shared: SharedSidecarAdapter(coordinator: one))
        let b = TranscriptStore(baseDirectory: right, shared: SharedSidecarAdapter(coordinator: two))
        _ = try await a.loadTranscript(for: "Meeting.mp3"); _ = try await b.loadTranscript(for: "Meeting.mp3")
        func replacement(_ text: String) -> Transcript {
            Transcript(recordingFilename: "Meeting.mp3", transcriptionModel: "fixture", hasSpeakerLabels: false,
                       segments: [.init(startTime: 0, endTime: 1, text: text)])
        }
        try await a.save(replacement("Left competing content"), mp3Filename: "Meeting.mp3")
        try await b.save(replacement("Right competing content"), mp3Filename: "Meeting.mp3")
        try deliver(left, right, writer: one.writerID)
        try deliver(right, left, writer: two.writerID)
        let reopened = SharedLibraryCoordinator(root: right, writerID: two.writerID, witnessDirectory: secondDirectory.appendingPathComponent("local"))
        _ = try await reopened.projectOutputs()
        let json = try Data(contentsOf: right.appendingPathComponent("Meeting.transcript.json"))
        let content = try SharedContentCoding.decoder().decode(Transcript.self, from: json)
        XCTAssertEqual(content.segments.first?.text, "Readable fixture")
        let marker = try SharedProjectionDocument.marker(in: json)
        XCTAssertTrue(marker?.hasConflicts == true)
        let markdown = String(decoding: try Data(contentsOf: right.appendingPathComponent("Meeting.transcript.md")), as: UTF8.self)
        XCTAssertTrue(markdown.contains("Readable fixture"))
        XCTAssertFalse(markdown.contains("Left competing content"))
        XCTAssertFalse(markdown.contains("Right competing content"))
    }

    func testSidecarReviewAdoptsChangedFileAndPublishesReadableText() async throws {
        let (root, coordinator) = try await fixture()
        _ = try await coordinator.projectOutputs()
        let entity = SharedEntityIdentity(id: try await coordinator.recording(at: "Meeting.mp3").state.id, kind: .recording)
        let cleanReviews = try await coordinator.reviewSidecars(entity)
        XCTAssertTrue(cleanReviews.isEmpty)
        let url = root.appendingPathComponent("Meeting.transcript.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var segments = try XCTUnwrap(object["segments"] as? [[String: Any]])
        segments[0]["text"] = "Changed on another computer"
        object["segments"] = segments
        try JSONSerialization.data(withJSONObject: object, options: .sortedKeys).write(to: url, options: .atomic)
        let reviews = try await coordinator.reviewSidecars(entity)
        let review = try XCTUnwrap(reviews.first)
        XCTAssertEqual(review.currentText, "[s] Readable fixture")
        XCTAssertTrue(review.changedText?.contains("Changed on another computer") == true)
        _ = try await coordinator.recoverSidecar(review, useChangedFile: true)
        _ = try await coordinator.projectOutputs()
        XCTAssertTrue(String(decoding: try Data(contentsOf: root.appendingPathComponent("Meeting.transcript.md")), as: UTF8.self).contains("Changed on another computer"))
        let remainingReviews = try await coordinator.reviewSidecars(entity)
        XCTAssertTrue(remainingReviews.isEmpty)
    }
    func testDamagedSidecarRestoresCurrentContentIncludingSpeakerEdits() async throws {
        let (root, coordinator) = try await fixture()
        let original = try await coordinator.recording(at: "Meeting.mp3")
        var body = try JSONSerialization.jsonObject(with: original.state.currentDocument(for: .transcript)!.json) as! [String: Any]
        body["futureExtension"] = ["keep": "unknown content"]
        _ = try await coordinator.edit(.init(base: original, changes: [.generation(try SharedDocument(id: UUID(), json: JSONSerialization.data(withJSONObject: body)), component: .transcript)]))
        let store = TranscriptStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: coordinator))
        _ = try await store.loadTranscript(for: "Meeting.mp3")
        try await store.updateSpeakerNames(for: "Meeting.mp3", names: ["s": "Alice"])
        _ = try await coordinator.projectOutputs()
        let entity = SharedEntityIdentity(id: try await coordinator.recording(at: "Meeting.mp3").state.id, kind: .recording)
        let url = root.appendingPathComponent("Meeting.transcript.json")
        try Data("{damaged sync file".utf8).write(to: url, options: .atomic)
        let reviews = try await coordinator.reviewSidecars(entity)
        let review = try XCTUnwrap(reviews.first)
        XCTAssertNil(review.changedText)
        XCTAssertTrue(review.currentText.contains("Alice"))
        do { _ = try await coordinator.recoverSidecar(review, useChangedFile: true); XCTFail("Damaged content cannot become a generation") }
        catch SharedSidecarError.invalidContent { }
        _ = try await coordinator.recoverSidecar(review, useChangedFile: false)
        _ = try await coordinator.projectOutputs()
        let recovered = try SharedContentCoding.decoder().decode(Transcript.self, from: Data(contentsOf: url))
        XCTAssertEqual(recovered.speakerNames["s"], "Alice")
        let restoredBody = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        XCTAssertEqual((restoredBody["futureExtension"] as? [String: String])?["keep"], "unknown content")
        XCTAssertEqual(recovered.segments.first?.text, "Readable fixture")
        let remainingReviews = try await coordinator.reviewSidecars(entity)
        XCTAssertTrue(remainingReviews.isEmpty)
    }
    func testSidecarRecoveryRefusesChangedFileAndChangedReview() async throws {
        let (root, coordinator) = try await fixture()
        _ = try await coordinator.projectOutputs()
        let first = try await coordinator.recording(at: "Meeting.mp3")
        let entity = SharedEntityIdentity(id: first.state.id, kind: .recording)
        let url = root.appendingPathComponent("Meeting.transcript.json")
        try Data("first damaged file".utf8).write(to: url, options: .atomic)
        let firstReviews = try await coordinator.reviewSidecars(entity)
        let firstReview = try XCTUnwrap(firstReviews.first)
        let second = Data("new unseen changed file".utf8)
        try second.write(to: url, options: .atomic)
        do { _ = try await coordinator.recoverSidecar(firstReview, useChangedFile: false); XCTFail("Never replace unseen bytes") }
        catch SharedLibraryCoordinatorError.externalChanged { }
        XCTAssertEqual(try Data(contentsOf: url), second)
        let secondReviews = try await coordinator.reviewSidecars(entity)
        let secondReview = try XCTUnwrap(secondReviews.first)
        _ = try await coordinator.edit(.init(base: first, changes: [.assign(field: "title", value: .text("Changed title"))]))
        do { _ = try await coordinator.recoverSidecar(secondReview, useChangedFile: false); XCTFail("Reload a changed review") }
        catch SharedLibraryCoordinatorError.staleReview { }
        XCTAssertEqual(try Data(contentsOf: url), second)
    }

    func testSidecarRecoveryCannotAdoptInvalidTimesOrOverwriteUnseenPostAcceptanceBytes() async throws {
        let (root, coordinator) = try await fixture()
        _ = try await coordinator.projectOutputs()
        let entity = SharedEntityIdentity(id: try await coordinator.recording(at: "Meeting.mp3").state.id, kind: .recording)
        let url = root.appendingPathComponent("Meeting.transcript.json")
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        var segments = object["segments"] as! [[String: Any]]
        segments[0]["startTime"] = -1; object["segments"] = segments
        try JSONSerialization.data(withJSONObject: object).write(to: url, options: .atomic)
        let reviews = try await coordinator.reviewSidecars(entity)
        let review = try XCTUnwrap(reviews.first)
        XCTAssertNil(review.changedText)
        _ = try await coordinator.recoverSidecar(review, useChangedFile: false)
        let unseen = Data("new cloud bytes after reviewed choice".utf8)
        try unseen.write(to: url, options: .atomic)
        do { _ = try await coordinator.projectOutputs(); XCTFail("Never overwrite a file changed after acceptance") }
        catch SharedProjectionWriteError.untracked(let path) { XCTAssertEqual(path, "Meeting.transcript.json") }
        XCTAssertEqual(try Data(contentsOf: url), unseen)
    }

    func testCompletedExternalApprovalCannotAuthorizeReappearanceOrLaterGeneration() async throws {
        let (root, coordinator) = try await fixture()
        _ = try await coordinator.projectOutputs()
        let entity = SharedEntityIdentity(id: try await coordinator.recording(at: "Meeting.mp3").state.id, kind: .recording)
        let url = root.appendingPathComponent("Meeting.transcript.json")
        let external = Data("{damaged external file requiring one review".utf8)
        try external.write(to: url, options: .atomic)
        let reviews = try await coordinator.reviewSidecars(entity)
        _ = try await coordinator.recoverSidecar(XCTUnwrap(reviews.first), useChangedFile: false)
        _ = try await coordinator.projectOutputs()
        try external.write(to: url, options: .atomic)
        do { _ = try await coordinator.projectOutputs(); XCTFail("Completed approval cannot silently consume a new occurrence") }
        catch SharedProjectionWriteError.untracked(let path) { XCTAssertEqual(path, "Meeting.transcript.json") }
        XCTAssertEqual(try Data(contentsOf: url), external)
        let fresh = try await coordinator.read(entity)
        let next = Transcript(recordingFilename: "Meeting.mp3", transcriptionModel: "new generation", hasSpeakerLabels: false,
            segments: [.init(startTime: 0, endTime: 1, text: "A later current transcript")])
        _ = try await coordinator.edit(.init(base: fresh, changes: [.generation(try SharedDocument(id: UUID(), json: JSONEncoder().encode(next)), component: .transcript)]))
        try external.write(to: url, options: .atomic)
        do { _ = try await coordinator.projectOutputs(); XCTFail("A different generation cannot inherit previous file approval") }
        catch SharedProjectionWriteError.untracked(let path) { XCTAssertEqual(path, "Meeting.transcript.json") }
        XCTAssertEqual(try Data(contentsOf: url), external)
    }

    func testBootstrapInputApprovalCannotBeReusedAfterCanonicalPublication() async throws {
        let (root, coordinator) = try await fixture()
        let paths = ["Meeting.transcript.json", "library.json", ".templates.json"]
        let originals = try Dictionary(uniqueKeysWithValues: paths.map { ($0, try Data(contentsOf: root.appendingPathComponent($0))) })
        _ = try await coordinator.projectOutputs()
        let canonical = try Dictionary(uniqueKeysWithValues: paths.map { ($0, try Data(contentsOf: root.appendingPathComponent($0))) })
        for path in paths {
            let url = root.appendingPathComponent(path), old = originals[path]!
            try old.write(to: url, options: .atomic)
            do { _ = try await coordinator.projectOutputs(); XCTFail("Published bootstrap bytes need a new review: " + path) }
            catch SharedProjectionWriteError.untracked(let rejected) { XCTAssertEqual(rejected, path) }
            XCTAssertEqual(try Data(contentsOf: url), old)
            try canonical[path]!.write(to: url, options: .atomic)
        }
    }

    func testExternalApprovalSurvivesPendingProjectionBeforeSidecarWrite() async throws {
        let (root, coordinator) = try await fixture()
        _ = try await coordinator.projectOutputs()
        let view = try await coordinator.recording(at: "Meeting.mp3")
        let entity = SharedEntityIdentity(id: view.state.id, kind: .recording)
        let url = root.appendingPathComponent("Meeting.transcript.json")
        var body = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        body["transcriptionModel"] = "Reviewed external generation"
        let bytes = try JSONSerialization.data(withJSONObject: body, options: .sortedKeys)
        try bytes.write(to: url, options: .atomic)
        let inspected = try await coordinator.inspectExternal(entity, component: .transcript, at: url)
        _ = try await coordinator.adoptExternal(XCTUnwrap(inspected), review: view)
        do {
            _ = try await coordinator.projectOutputs(afterOutput: { index in if index == 1 { throw CancellationError() } })
            XCTFail("Interrupt after aggregate output but before sidecar write")
        } catch is CancellationError { }
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        _ = try await coordinator.projectOutputs()
        let transcript = try SharedContentCoding.decoder().decode(Transcript.self, from: Data(contentsOf: url))
        XCTAssertEqual(transcript.transcriptionModel, "Reviewed external generation")
        let remaining = try await coordinator.reviewSidecars(entity)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testInterruptedSidecarWriteCannotReplayExternalOrBootstrapConsent() async throws {
        for explicit in [false, true] {
            let (root, coordinator) = try await fixture()
            let url = root.appendingPathComponent("Meeting.transcript.json")
            var original = try Data(contentsOf: url)
            if explicit {
                _ = try await coordinator.projectOutputs()
                original = Data("{reviewed damaged input".utf8)
                try original.write(to: url, options: .atomic)
                let entity = SharedEntityIdentity(id: try await coordinator.recording(at: "Meeting.mp3").state.id, kind: .recording)
                let reviews = try await coordinator.reviewSidecars(entity)
                _ = try await coordinator.recoverSidecar(XCTUnwrap(reviews.first), useChangedFile: false)
            }
            do {
                _ = try await coordinator.projectOutputs(afterOutput: { index in if index == 2 { throw CancellationError() } })
                XCTFail("Interrupt after the actual sidecar write")
            } catch is CancellationError { }
            XCTAssertNotNil(try SharedProjectionDocument.marker(in: Data(contentsOf: url)))
            try original.write(to: url, options: .atomic)
            do { _ = try await coordinator.projectOutputs(); XCTFail("Interrupted sidecar write cannot reuse consent: explicit=\(explicit)") }
            catch SharedProjectionWriteError.untracked(let path) { XCTAssertEqual(path, "Meeting.transcript.json") }
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
    }

    func testInterruptedBeforeSidecarWriteRequiresFreshReviewAndCanRecover() async throws {
        let (root, coordinator) = try await fixture()
        _ = try await coordinator.projectOutputs()
        let entity = SharedEntityIdentity(id: try await coordinator.recording(at: "Meeting.mp3").state.id, kind: .recording)
        let url = root.appendingPathComponent("Meeting.transcript.json")
        let raw = Data("{reviewed pending input".utf8)
        try raw.write(to: url, options: .atomic)
        let first = try await coordinator.reviewSidecars(entity)
        _ = try await coordinator.recoverSidecar(XCTUnwrap(first.first), useChangedFile: false)
        do {
            _ = try await coordinator.projectOutputs(beforeOutput: { index in if index == 2 { throw CancellationError() } })
            XCTFail("Stop after the durable attempt but before the sidecar write")
        } catch is CancellationError { }
        XCTAssertEqual(try Data(contentsOf: url), raw)
        do { _ = try await coordinator.projectOutputs(); XCTFail("Uncertain raw input needs a new review") }
        catch SharedProjectionWriteError.untracked { }
        let fresh = try await coordinator.reviewSidecars(entity)
        _ = try await coordinator.recoverSidecar(XCTUnwrap(fresh.first), useChangedFile: false)
        _ = try await coordinator.projectOutputs()
        XCTAssertNotNil(try SharedProjectionDocument.marker(in: Data(contentsOf: url)))
    }
    func testSourceChangedAtOutputBoundaryCannotBeOverwritten() async throws {
        let (root, coordinator) = try await fixture()
        _ = try await coordinator.projectOutputs()
        let entity = SharedEntityIdentity(id: try await coordinator.recording(at: "Meeting.mp3").state.id, kind: .recording)
        let url = root.appendingPathComponent("Meeting.transcript.json")
        try Data("{reviewed source".utf8).write(to: url, options: .atomic)
        let reviews = try await coordinator.reviewSidecars(entity)
        _ = try await coordinator.recoverSidecar(XCTUnwrap(reviews.first), useChangedFile: false)
        let unseen = Data("{unseen input arrived at the output boundary".utf8)
        do {
            _ = try await coordinator.projectOutputs(beforeOutput: { index in
                if index == 2 { try unseen.write(to: url, options: .atomic) }
            })
            XCTFail("Unseen input must survive a change during publication")
        } catch SharedProjectionWriteError.stale { }
        XCTAssertEqual(try Data(contentsOf: url), unseen)
    }

    func testOwnPublicationIncludingSpeakerEditsIsNotAnExternalCandidate() async throws {
        let (root, coordinator) = try await fixture()
        let store = TranscriptStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: coordinator))
        _ = try await store.loadTranscript(for: "Meeting.mp3")
        try await store.updateSpeakerNames(for: "Meeting.mp3", names: ["s": "Alice"])
        _ = try await coordinator.projectOutputs()
        let entity = SharedEntityIdentity(id: try await coordinator.recording(at: "Meeting.mp3").state.id, kind: .recording)
        let candidate = try await coordinator.inspectExternal(entity, component: .transcript, at: root.appendingPathComponent("Meeting.transcript.json"))
        XCTAssertNil(candidate)
    }
    func testEditedMarkedJSONAdoptionStripsProducerMarkerAndAllowsExactPublication() async throws {
        let (root, coordinator) = try await fixture()
        _ = try await coordinator.projectOutputs()
        let before = try await coordinator.recording(at: "Meeting.mp3")
        let entity = SharedEntityIdentity(id: before.state.id, kind: .recording)
        let url = root.appendingPathComponent("Meeting.transcript.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object["transcriptionModel"] = "External edit"
        let external = try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
        try external.write(to: url)
        let inspected = try await coordinator.inspectExternal(entity, component: .transcript, at: url)
        let candidate = try XCTUnwrap(inspected)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: candidate.document.json) as? [String: Any])
        XCTAssertNil(body["_docktape"])
        XCTAssertEqual(candidate.fingerprint, try SharedStateFingerprint.of(external))
        _ = try await coordinator.adoptExternal(candidate, review: before)
        _ = try await coordinator.projectOutputs()
        let published = try Data(contentsOf: url)
        XCTAssertNotNil(try SharedProjectionDocument.marker(in: published))
        let transcript = try SharedContentCoding.decoder().decode(Transcript.self, from: published)
        XCTAssertEqual(transcript.transcriptionModel, "External edit")
        let next = try await coordinator.inspectExternal(entity, component: .transcript, at: url)
        XCTAssertNil(next)
    }
    func testForeignRecordingMarkerCannotBeAdoptedAtLocalSidecarPath() async throws {
        let (root, coordinator) = try await fixture()
        _ = try await coordinator.projectOutputs()
        let view = try await coordinator.recording(at: "Meeting.mp3")
        let entity = SharedEntityIdentity(id: view.state.id, kind: .recording)
        let url = root.appendingPathComponent("Meeting.transcript.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var marker = try XCTUnwrap(object["_docktape"] as? [String: Any])
        marker["entities"] = [UUID().uuidString]
        object["_docktape"] = marker
        let foreign = try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
        try foreign.write(to: url)
        do { _ = try await coordinator.inspectExternal(entity, component: .transcript, at: url); XCTFail("Do not attribute another recording's JSON to this one") }
        catch SharedLibraryCoordinatorError.differentBinding {}
        XCTAssertEqual(try Data(contentsOf: url), foreign)
    }

    func testConcurrentGenerationCannotUseAdoptionApprovalToOverwriteWithConfirmedFallback() async throws {
        let (left, one) = try await fixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        roots.append(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let right = directory.appendingPathComponent("library")
        try FileManager.default.copyItem(at: left, to: right)
        let two = SharedLibraryCoordinator(root: right, writerID: UUID(), witnessDirectory: directory.appendingPathComponent("local"))
        try await two.requestEnrollment(requestID: UUID(), label: "Fixture B")
        try deliver(right, left, writer: two.writerID)
        for _ in 0..<3 {
            try await one.refresh(); try deliver(left, right, writer: one.writerID)
            try await two.refresh(); try deliver(right, left, writer: two.writerID)
        }
        _ = try await one.projectOutputs()
        let view = try await one.recording(at: "Meeting.mp3")
        let entity = SharedEntityIdentity(id: view.state.id, kind: .recording)
        let url = left.appendingPathComponent("Meeting.transcript.json")
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        raw["transcriptionModel"] = "Reviewed external content"
        let external = try JSONSerialization.data(withJSONObject: raw, options: .sortedKeys)
        try external.write(to: url)
        let inspected = try await one.inspectExternal(entity, component: .transcript, at: url)
        _ = try await one.adoptExternal(XCTUnwrap(inspected), review: view)
        let other = TranscriptStore(baseDirectory: right, shared: SharedSidecarAdapter(coordinator: two))
        _ = try await other.loadTranscript(for: "Meeting.mp3")
        try await other.save(Transcript(recordingFilename: "Meeting.mp3", transcriptionModel: "Concurrent generation", hasSpeakerLabels: false,
            segments: [.init(startTime: 0, endTime: 1, text: "Competing content")]), mp3Filename: "Meeting.mp3")
        try deliver(left, right, writer: one.writerID)
        try deliver(right, left, writer: two.writerID)
        let contested = try await one.read(entity)
        XCTAssertNil(contested.state.currentDocument(for: .transcript))
        do { _ = try await one.projectOutputs(); XCTFail("Adoption approval only covers its selected generation") }
        catch SharedProjectionWriteError.untracked("Meeting.transcript.json") {}
        XCTAssertEqual(try Data(contentsOf: url), external)
    }

}
