// © 2026 High Gain Design. All rights reserved.
import XCTest
@testable import HiDockKit

final class SharedFolderLifecycleReviewTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() { for root in roots { try? FileManager.default.removeItem(at: root) } }
    private struct Fixture {
        let root: URL
        let a: SharedLibraryCoordinator
        let folder: SharedEntityIdentity
        let child: SharedEntityIdentity
        let unrelated: SharedEntityIdentity
    }
    private func fixture(deletedChild: Bool = false) async throws -> Fixture {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); roots.append(parent)
        let left = parent.appendingPathComponent("left"), right = parent.appendingPathComponent("right")
        try FileManager.default.createDirectory(at: left.appendingPathComponent("Folder"), withIntermediateDirectories: true)
        for path in ["Folder/Clip.mp3", "Unrelated.mp3"] { try Data(path.utf8).write(to: left.appendingPathComponent(path)) }
        try await TranscriptStore(baseDirectory: left).save(Transcript(recordingFilename: "Folder/Clip.mp3", transcriptionModel: "fixture", hasSpeakerLabels: false,
            segments: [.init(startTime: 0, endTime: 1, text: "Retained child conversation")]), mp3Filename: "Folder/Clip.mp3")
        let a = SharedLibraryCoordinator(root: left, writerID: UUID(), witnessDirectory: parent.appendingPathComponent("a-local"))
        _ = try await a.enable(); _ = try await a.projectOutputs()
        let folders = try await a.snapshots(kinds: [.folder]), folder = SharedEntityIdentity(id: try XCTUnwrap(folders.first { $0.state.value(for: "name") == .text("Folder") }).state.id, kind: .folder)
        let child = SharedEntityIdentity(id: try await a.reference(to: "Folder/Clip.mp3").entityID, kind: .recording)
        let unrelated = SharedEntityIdentity(id: try await a.reference(to: "Unrelated.mp3").entityID, kind: .recording)
        if deletedChild { _ = try await a.edit(.init(base: try await a.read(child), changes: [.delete])) }
        try FileManager.default.copyItem(at: left, to: right)
        let b = SharedLibraryCoordinator(root: right, writerID: UUID(), witnessDirectory: parent.appendingPathComponent("b-local"))
        try await b.requestEnrollment(requestID: UUID(), label: "Lifecycle peer")
        for _ in 0..<3 { try deliver(right, to: left, writer: b.writerID); try await a.refresh(); try deliver(left, to: right, writer: a.writerID); try await b.refresh() }
        // Controlled causal phase: root deletion competes with a peer root edit.
        // No physical removal or implicit child deletion is claimed by this fixture.
        _ = try await a.edit(.init(base: try await a.read(folder), changes: [.delete]))
        _ = try await b.edit(.init(base: try await b.read(folder), changes: [.assign(field: "name", value: .text("Folder"))]))
        try deliver(right, to: left, writer: b.writerID)
        return .init(root: left, a: a, folder: folder, child: child, unrelated: unrelated)
    }
    private func choice(_ f: Fixture, keep: Bool = true) async throws -> SharedFolderLifecycleReview {
        let choices = try await f.a.folderLifecycleChoices(f.a.read(f.folder))
        return try XCTUnwrap(choices.first { $0.keep == keep })
    }
    func testKeepPreservesDeletedChildAndRetainedContent() async throws {
        let f = try await fixture(deletedChild: true), selected = try await choice(f)
        let member = try XCTUnwrap(selected.members.first { $0.state.id == f.child.id })
        XCTAssertEqual(member.path, "Folder/Clip.mp3"); XCTAssertEqual(member.state.lifecycle, .deleted)
        let document = try XCTUnwrap(member.state.currentDocument(for: .transcript))
        XCTAssertEqual(try document.decode(Transcript.self).segments.first?.text, "Retained child conversation")
        let before = try await f.a.read(f.child)
        let kept = try await f.a.resolveFolderLifecycle(selected)
        XCTAssertEqual(kept.state.lifecycle, .alive); XCTAssertEqual(kept.state.fields["deletionRequest"]?.resolvedValue, .unset)
        let after = try await f.a.read(f.child)
        XCTAssertEqual(after.state, before.state, "Root Keep must not restore/delete/edit descendants")
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("Folder/Clip.mp3")), Data("Folder/Clip.mp3".utf8))
    }
    func testFolderLifecycleRefusesChangedChildContent() async throws {
        let f = try await fixture(), selected = try await choice(f)
        _ = try await f.a.edit(.init(base: try await f.a.read(f.child), changes: [.assign(field: "metadata.mode", value: .text("\"Mee\""))]))
        do { _ = try await f.a.resolveFolderLifecycle(selected); XCTFail("Child state shown during review changed") }
        catch SharedLibraryCoordinatorError.staleReview { }
        let fresh = try await choice(f)
        XCTAssertNotEqual(selected.contextFingerprint, fresh.contextFingerprint)
        let root = try await f.a.read(f.folder); XCTAssertEqual(root.state.lifecycle, .conflicted)
    }
    func testFolderLifecycleRefusesChildLifecycleABA() async throws {
        let f = try await fixture(), selected = try await choice(f, keep: false)
        _ = try await f.a.edit(.init(base: try await f.a.read(f.child), changes: [.delete]))
        _ = try await f.a.resolve(.init(base: try await f.a.read(f.child), changes: [.restore]))
        do { _ = try await f.a.resolveFolderLifecycle(selected); XCTFail("Returned display lifecycle does not restore old consent") }
        catch SharedLibraryCoordinatorError.staleReview { }
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("Folder/Clip.mp3")), Data("Folder/Clip.mp3".utf8))
    }
    func testFolderLifecyclePreservesUnrelatedEditsAndRefusesCopiedRoot() async throws {
        let f = try await fixture(), selected = try await choice(f)
        let copied = SharedLibraryCoordinator(root: f.root.deletingLastPathComponent().appendingPathComponent("right"), writerID: UUID())
        do { _ = try await copied.resolveFolderLifecycle(selected); XCTFail("Copied root is a different reviewed binding") }
        catch SharedLibraryCoordinatorError.differentBinding { }
        _ = try await f.a.edit(.init(base: try await f.a.read(f.unrelated), changes: [.assign(field: "metadata.mode", value: .text("\"Mee\""))]))
        _ = try await f.a.resolveFolderLifecycle(selected)
        let unrelated = try await f.a.read(f.unrelated)
        XCTAssertEqual(unrelated.state.value(for: "metadata.mode"), .text("\"Mee\""))
    }
    func testFolderLifecycleRefusesLateNamespaceCollision() async throws {
        let f = try await fixture(), selected = try await choice(f)
        do {
            _ = try await f.a.resolveFolderLifecycle(selected, beforeCommit: {
                _ = try await f.a.edit(.init(base: try await f.a.read(f.unrelated), changes: [.assign(field: "title", value: .text("Clip")), .assign(field: "folder", value: .text(f.folder.id.uuidString))]))
            }); XCTFail("A late identity collision invalidates the reviewed namespace")
        } catch { }
        let root = try await f.a.read(f.folder); XCTAssertEqual(root.state.lifecycle, .conflicted)
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("Unrelated.mp3")), Data("Unrelated.mp3".utf8))
    }
    private actor Once {
        private var available = true
        func take() -> Bool { defer { available = false }; return available }
    }
    func testFolderLifecycleRefusesChildChangedDuringAuthorityAcquisition() async throws {
        let f = try await fixture(), selected = try await choice(f), once = Once()
        let raced = SharedLibraryCoordinator(root: f.root, writerID: f.a.writerID, witnessDirectory: f.root.deletingLastPathComponent().appendingPathComponent("a-local"), afterPublishedLibraryRead: {
            if await once.take() { _ = try await f.a.edit(.init(base: try await f.a.read(f.child), changes: [.assign(field: "metadata.mode", value: .text("\"Rec\""))])) }
        })
        do { _ = try await raced.resolveFolderLifecycle(selected); XCTFail("Fresh acquisition must not bless an old descendant preview") }
        catch SharedLibraryOperationError.staleAuthority { }
        catch SharedLibraryCoordinatorError.staleReview { }
        let root = try await f.a.read(f.folder); XCTAssertEqual(root.state.lifecycle, .conflicted)
    }
    private struct EmptyFixture {
        let root: URL
        let a: SharedLibraryCoordinator
        let folder: SharedEntityIdentity
        let witness: URL
        let receipt: URL
    }
    private func emptyFixture(peerRename: Bool = true) async throws -> EmptyFixture {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); roots.append(parent)
        let left = parent.appendingPathComponent("left"), right = parent.appendingPathComponent("right"), witness = parent.appendingPathComponent("a-local")
        try FileManager.default.createDirectory(at: left.appendingPathComponent("Empty"), withIntermediateDirectories: true)
        let a = SharedLibraryCoordinator(root: left, writerID: UUID(), witnessDirectory: witness)
        let manifest = try await a.enable(); _ = try await a.projectOutputs()
        let folders = try await a.snapshots(kinds: [.folder]), folder = SharedEntityIdentity(id: try XCTUnwrap(folders.first { $0.state.value(for: "name") == .text("Empty") }).state.id, kind: .folder)
        try FileManager.default.copyItem(at: left, to: right)
        let b = SharedLibraryCoordinator(root: right, writerID: UUID(), witnessDirectory: parent.appendingPathComponent("b-local"))
        try await b.requestEnrollment(requestID: UUID(), label: "Retention peer")
        for _ in 0..<3 { try deliver(right, to: left, writer: b.writerID); try await a.refresh(); try deliver(left, to: right, writer: a.writerID); try await b.refresh() }
        let outcome = try await a.deleteFolder(named: "Empty")
        XCTAssertEqual(outcome.result, .waitingForAcknowledgments)
        if peerRename {
            _ = try await b.renameFolder(from: "Empty", to: "Away")
            _ = try await b.renameFolder(from: "Away", to: "Empty")
        } else {
            _ = try await b.edit(.init(base: try await b.read(folder), changes: [.assign(field: "name", value: .text("Empty"))]))
        }
        try deliver(right, to: left, writer: b.writerID)
        return .init(root: left, a: a, folder: folder, witness: witness,
            receipt: witness.appendingPathComponent("Operations/" + manifest.libraryID.uuidString + "/" + a.writerID.uuidString + "/" + folder.id.uuidString + ".json"))
    }
    private func retain(_ f: EmptyFixture) async throws -> SharedFolderOperationReview {
        let choices = try await f.a.folderLifecycleChoices(f.a.read(f.folder))
        _ = try await f.a.resolveFolderLifecycle(XCTUnwrap(choices.first { $0.keep }))
        let review = try await f.a.reviewFolderOperation(id: f.folder.id)
        let row = try XCTUnwrap(review)
        XCTAssertTrue(row.canReplan); XCTAssertFalse(row.canResume); XCTAssertFalse(row.canAcknowledge)
        return row
    }
    func testRetentionReplaysAcceptedPlanAfterRestartWithoutReusingDeletion() async throws {
        let f = try await emptyFixture(peerRename: false)
        let old = try SharedOperationReceipt.decode(Data(contentsOf: f.receipt))
        XCTAssertEqual(old.operation.steps, [.removeEmptyDirectory(path: "Empty")])
        XCTAssertEqual(old.completed, 0); XCTAssertFalse(old.attempting)
        let row = try await retain(f)
        let notes = Data("Keep ordinary notes".utf8)
        try notes.write(to: f.root.appendingPathComponent("Empty/.notes"))
        let interrupted = SharedLibraryCoordinator(root: f.root, writerID: f.a.writerID, witnessDirectory: f.witness,
            afterCommit: { withUnsafeCurrentTask { $0?.cancel() } })
        let plan = try await interrupted.prepareFolderReplan(row)
        XCTAssertEqual(plan.source, "Empty"); XCTAssertEqual(plan.destination, "Empty"); XCTAssertEqual(plan.files, [".notes"])
        do { _ = try await Task { try await interrupted.applyFolderReplan(plan) }.value; XCTFail("Expected interruption after accepted plan") }
        catch is CancellationError { }
        let held = try SharedOperationReceipt.decode(Data(contentsOf: f.receipt))
        XCTAssertEqual(held.operation, old.operation); XCTAssertEqual(held.completed, old.completed); XCTAssertEqual(held.attempting, old.attempting)
        let restarted = SharedLibraryCoordinator(root: f.root, writerID: f.a.writerID, witnessDirectory: f.witness)
        let outcome = try await restarted.resumeFolderOperation(id: f.folder.id)
        XCTAssertEqual(outcome.result, .complete)
        let final = try SharedOperationReceipt.decode(Data(contentsOf: f.receipt))
        XCTAssertNotEqual(final.operation.id, old.operation.id)
        XCTAssertEqual(final.operation.inputRevision, old.operation.outputRevision)
        XCTAssertEqual(final.completed, 1); XCTAssertFalse(final.attempting)
        guard case .moveDirectory(let source, let destination, let inventory) = try XCTUnwrap(final.operation.steps.first) else { return XCTFail("Keep must replace cleanup with an inventory-only phase") }
        XCTAssertEqual(source, "Empty"); XCTAssertEqual(destination, "Empty"); XCTAssertEqual(inventory.entries.map(\.path), [".notes"])
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("Empty/.notes")), notes)
        let remaining = try await restarted.reviewFolderOperation(id: f.folder.id); XCTAssertNil(remaining)
        let completedBytes = try Data(contentsOf: f.receipt)
        let repeated = try await restarted.resumeFolderOperation(id: f.folder.id)
        XCTAssertEqual(repeated.result, .complete); XCTAssertEqual(try Data(contentsOf: f.receipt), completedBytes)
        let renamed = try await restarted.renameFolder(from: "Empty", to: "After")
        XCTAssertEqual(renamed.result, .complete); XCTAssertEqual(renamed.id, f.folder.id)
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("After/.notes")), notes)
    }
    func testRetentionCannotRecreateMissingSource() async throws {
        let f = try await emptyFixture(), row = try await retain(f)
        try FileManager.default.removeItem(at: f.root.appendingPathComponent("Empty"))
        let before = try Data(contentsOf: f.receipt)
        do { _ = try await f.a.prepareFolderReplan(row); XCTFail("Missing source needs provider recovery; Keep cannot fabricate it") }
        catch SharedLibraryOperationError.pathConflict { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("Empty").path))
        XCTAssertEqual(try Data(contentsOf: f.receipt), before)
    }
    func testRetentionRefusesInventoryChangedAfterPreview() async throws {
        let f = try await emptyFixture(), row = try await retain(f)
        let plan = try await f.a.prepareFolderReplan(row), before = try Data(contentsOf: f.receipt)
        let notes = Data("Arrived after review".utf8)
        try notes.write(to: f.root.appendingPathComponent("Empty/.notes"))
        do { _ = try await f.a.applyFolderReplan(plan); XCTFail("Fresh inventory is not the reviewed inventory") }
        catch SharedLibraryOperationError.contentChanged { }
        XCTAssertEqual(try Data(contentsOf: f.receipt), before)
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("Empty/.notes")), notes)
    }
    func testFolderLifecycleRefusesChildContentChangedBeforeCommit() async throws {
        let f = try await fixture(), selected = try await choice(f)
        do {
            _ = try await f.a.resolveFolderLifecycle(selected, beforeCommit: {
                _ = try await f.a.edit(.init(base: try await f.a.read(f.child), changes: [.assign(field: "metadata.mode", value: .text("\"Rec\""))]))
            }); XCTFail("Late descendant edits invalidate the reviewed root decision")
        } catch SharedLibraryRepositoryError.staleRevision { }
        let root = try await f.a.read(f.folder); XCTAssertEqual(root.state.lifecycle, .conflicted)
        let child = try await f.a.read(f.child); XCTAssertEqual(child.state.value(for: "metadata.mode"), .text("\"Rec\""))
    }
    private func deliver(_ source: URL, to destination: URL, writer: UUID) throws {
        let tree = source.appendingPathComponent(".docktape").resolvingSymlinksInPath()
        let iterator = try XCTUnwrap(FileManager.default.enumerator(at: tree, includingPropertiesForKeys: [.isDirectoryKey]))
        for case let file as URL in iterator where file.pathExtension == "json" {
            guard (try file.resourceValues(forKeys: [.isDirectoryKey])).isDirectory != true else { continue }
            let bytes = try Data(contentsOf: file), object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            let payload = object["payload"] as? [String: Any]
            let owner = (object["writerID"] as? String) ?? (payload?["writer"] as? String) ?? (object["founder"] as? String)
            guard owner.flatMap(UUID.init(uuidString:)) == writer else { continue }
            let relative = String(file.resolvingSymlinksInPath().path.dropFirst(tree.path.count + 1)), target = destination.appendingPathComponent(".docktape/" + relative)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: target, options: .atomic)
        }
    }
}
