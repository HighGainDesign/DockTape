// © 2026 High Gain Design. All rights reserved.
import XCTest
@testable import HiDockKit

final class SharedFolderDeletionScopeTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() { for root in roots { try? FileManager.default.removeItem(at: root) } }
    private struct Fixture {
        let root: URL
        let peerRoot: URL
        let a: SharedLibraryCoordinator
        let b: SharedLibraryCoordinator
        let folder: SharedEntityIdentity
        let child: SharedEntityIdentity
        let audio: Data
    }
    private func fixture(caseRoot: URL? = nil, legacy: Bool = false, legacyHasHash: Bool = true) async throws -> Fixture {
        let parent = (caseRoot ?? FileManager.default.temporaryDirectory).appendingPathComponent(UUID().uuidString); roots.append(parent)
        let left = parent.appendingPathComponent("left"), right = parent.appendingPathComponent("right")
        try FileManager.default.createDirectory(at: left.appendingPathComponent("Empty"), withIntermediateDirectories: true)
        if caseRoot != nil { try FileManager.default.createDirectory(at: left.appendingPathComponent("empty"), withIntermediateDirectories: true) }
        let audio = Data("Synthetic late conversation".utf8)
        if legacy {
            try audio.write(to: left.appendingPathComponent("Late.mp3"))
            let metadata = RecordingStore.RecordingMeta(audioSHA256: legacyHasHash ? SharedLibraryOperation.fingerprint(audio) : nil)
            try JSONEncoder().encode(["Late.mp3": metadata]).write(to: left.appendingPathComponent("library.json"))
        }
        let trash = parent.appendingPathComponent("synthetic-trash")
        let a = SharedLibraryCoordinator(root: left, writerID: UUID(), witnessDirectory: parent.appendingPathComponent("a-local"), trash: { file in
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: file, to: trash.appendingPathComponent(UUID().uuidString + "-" + file.lastPathComponent))
        })
        _ = try await a.enable(); _ = try await a.projectOutputs()
        let folders = try await a.snapshots(kinds: [.folder])
        let folder = SharedEntityIdentity(id: try XCTUnwrap(folders.first { $0.state.value(for: "name") == .text("Empty") }).state.id, kind: .folder)
        try FileManager.default.copyItem(at: left, to: right)
        let b = SharedLibraryCoordinator(root: right, writerID: UUID(), witnessDirectory: parent.appendingPathComponent("b-local"))
        try await b.requestEnrollment(requestID: UUID(), label: "Late child peer")
        for _ in 0..<3 { try deliver(right, to: left, writer: b.writerID); try await a.refresh(); try deliver(left, to: right, writer: a.writerID); try await b.refresh() }
        let pending = try await a.deleteFolder(named: "Empty"); XCTAssertEqual(pending.result, .waitingForAcknowledgments)
        _ = try await b.renameFolder(from: "Empty", to: "Away")
        _ = try await b.renameFolder(from: "Away", to: "Empty")
        if !legacy {
            _ = try await b.importAudio(audio, entry: FileEntry(filename: "Late.hda", size: UInt32(audio.count)), rawMD5: String(repeating: "0", count: 32))
        }
        _ = try await b.relocateRecording(filename: "Late.mp3", toFolder: "Empty", changeFolder: true)
        let child = SharedEntityIdentity(id: try await b.reference(to: "Empty/Late.mp3").entityID, kind: .recording)
        try deliver(right, to: left, writer: b.writerID)
        if legacy { try FileManager.default.removeItem(at: left.appendingPathComponent("Late.mp3")) }
        try FileManager.default.copyItem(at: right.appendingPathComponent("Empty/Late.mp3"), to: left.appendingPathComponent("Empty/Late.mp3"))
        try Data(contentsOf: right.appendingPathComponent("library.json")).write(to: left.appendingPathComponent("library.json"), options: .atomic)
        let choices = try await a.folderLifecycleChoices(a.read(folder))
        _ = try await a.resolveFolderLifecycle(XCTUnwrap(choices.first { !$0.keep }))
        return .init(root: left, peerRoot: right, a: a, b: b, folder: folder, child: child, audio: audio)
    }
    func testLateChildRequiresUpdatedDeletionScopeBeforeApproval() async throws {
        let f = try await fixture()
        let root = try await f.a.read(f.folder), child = try await f.a.read(f.child)
        XCTAssertEqual(root.state.lifecycle, .deleted); XCTAssertEqual(child.state.lifecycle, .alive)
        let reviewed = try await f.a.reviewFolderOperation(id: f.folder.id), row = try XCTUnwrap(reviewed)
        XCTAssertFalse(row.canAcknowledge); XCTAssertFalse(row.canResume)
        XCTAssertTrue(row.needsReplanning, "A late child needs an explicit updated deletion scope, not an approval deadlock")
        XCTAssertTrue(row.canReviewDeletionScope)
        let scope = try await f.a.prepareFolderDeletionScope(row)
        XCTAssertEqual(scope.path, "Empty"); XCTAssertEqual(scope.members.map(\.path), ["Empty/Late.mp3"])
        XCTAssertEqual(scope.members.first?.state.lifecycle, .alive)
        _ = try await f.a.applyFolderDeletionScope(scope)
        let unchangedChild = try await f.a.read(f.child); XCTAssertEqual(unchangedChild.state, child.state)
        let permission = try await f.a.operationAuthority(entity: f.folder, paths: [])
        XCTAssertTrue(permission.approvedWriters(for: .delete).isEmpty, "Saving a child scope grants no deletion approval")
        let current = try await f.a.reviewFolderOperation(id: f.folder.id), ready = try XCTUnwrap(current)
        XCTAssertTrue(ready.canPrepareChildren); XCTAssertFalse(ready.canAcknowledge); XCTAssertFalse(ready.canResume)
        let preparation = try await f.a.prepareReviewedFolderChildren(ready)
        XCTAssertEqual(preparation.result, .waitingForAcknowledgments)
        let pendingChild = try await f.a.read(f.child); XCTAssertEqual(pendingChild.state.lifecycle, .deleted)
        let afterPreparation = try await f.a.operationAuthority(entity: f.folder, paths: [])
        XCTAssertTrue(afterPreparation.approvedWriters(for: .delete).isEmpty, "Preparing children must not approve the root")
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("Empty/Late.mp3")), f.audio)
        try deliver(f.root, to: f.peerRoot, writer: f.a.writerID)
        let peerChild = try await f.b.reviewRecordingOperation(id: f.child.id), childApproval = try XCTUnwrap(peerChild)
        XCTAssertTrue(childApproval.canAcknowledge)
        try await f.b.acknowledgeReviewedRecordingOperation(childApproval)
        try deliver(f.peerRoot, to: f.root, writer: f.b.writerID)
        let removedChild = try await f.a.resumeRecordingOperation(id: f.child.id)
        XCTAssertEqual(removedChild.result, .complete)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("Empty/Late.mp3").path))
        let trash = f.root.deletingLastPathComponent().appendingPathComponent("synthetic-trash")
        let trashed = try FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil)
        XCTAssertEqual(trashed.count, 1); XCTAssertEqual(try Data(contentsOf: XCTUnwrap(trashed.first)), f.audio)
        let rootRow = try await f.a.reviewFolderOperation(id: f.folder.id), rootApproval = try XCTUnwrap(rootRow)
        XCTAssertTrue(rootApproval.canAcknowledge)
        try await f.a.acknowledgeReviewedFolderOperation(rootApproval)
        try deliver(f.root, to: f.peerRoot, writer: f.a.writerID)
        let peerRootRow = try await f.b.reviewFolderOperation(id: f.folder.id), peerRootApproval = try XCTUnwrap(peerRootRow)
        XCTAssertTrue(peerRootApproval.canAcknowledge)
        try await f.b.acknowledgeReviewedFolderOperation(peerRootApproval)
        try deliver(f.peerRoot, to: f.root, writer: f.b.writerID)
        let note = f.root.appendingPathComponent("Empty/.unknown-note"), noteBytes = Data("Preserve unknown file".utf8)
        try noteBytes.write(to: note)
        let approved = try await f.a.reviewFolderOperation(id: f.folder.id), final = try XCTUnwrap(approved)
        XCTAssertTrue(final.canResume)
        let veto = try await f.a.resumeReviewedFolderOperation(final)
        XCTAssertEqual(veto.result, .directoryNotEmpty("Empty")); XCTAssertEqual(try Data(contentsOf: note), noteBytes)
        // Simulate the user's explicit external removal of only this synthetic note.
        try FileManager.default.removeItem(at: note)
        let completed = try await f.a.resumeReviewedFolderOperation(final)
        XCTAssertEqual(completed.result, .complete)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("Empty").path))
    }
    private func prepared(_ f: Fixture) async throws -> SharedFolderDeletionScopeReview {
        let pending = try await f.a.reviewFolderOperation(id: f.folder.id)
        return try await f.a.prepareFolderDeletionScope(XCTUnwrap(pending))
    }
    func testUpdatedScopeRefusesChildEditAfterPreview() async throws {
        let f = try await fixture(), scope = try await prepared(f)
        _ = try await f.a.edit(.init(base: try await f.a.read(f.child), changes: [.assign(field: "metadata.mode", value: .text("\"Rec\""))]))
        do { _ = try await f.a.applyFolderDeletionScope(scope); XCTFail("Changed child invalidates the displayed scope") }
        catch SharedLibraryCoordinatorError.staleReview { }
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("Empty/Late.mp3")), f.audio)
    }
    func testUpdatedScopeRefusesReceiptChangedAfterPreview() async throws {
        let f = try await fixture(), scope = try await prepared(f)
        let file = f.root.deletingLastPathComponent().appendingPathComponent("a-local/Operations/" + scope.original.base.libraryID.uuidString + "/" + f.a.writerID.uuidString + "/" + f.folder.id.uuidString + ".json")
        var receipt = try SharedOperationReceipt.decode(Data(contentsOf: file)); receipt.attempting = true
        let attempted = try receipt.encoded(); try attempted.write(to: file, options: .atomic)
        do { _ = try await f.a.applyFolderDeletionScope(scope); XCTFail("Root progress changed after review") }
        catch SharedLibraryCoordinatorError.staleReview { }
        XCTAssertEqual(try Data(contentsOf: file), attempted)
        let child = try await f.a.read(f.child); XCTAssertEqual(child.state.lifecycle, .alive)
    }
    func testChildPreparationRefusesChangedCohortBeforeAcceptance() async throws {
        let f = try await fixture(), scope = try await prepared(f)
        let root = try await f.a.applyFolderDeletionScope(scope)
        let authority = try await f.a.operationAuthority(entity: f.folder, paths: [])
        let thirdRoot = f.root.deletingLastPathComponent().appendingPathComponent("third")
        try FileManager.default.copyItem(at: f.root, to: thirdRoot)
        let third = SharedLibraryCoordinator(root: thirdRoot, writerID: UUID(), witnessDirectory: thirdRoot.deletingLastPathComponent().appendingPathComponent("third-local"))
        do {
            _ = try await f.a.resumeFolderDeletion(id: f.folder.id, reviewedFolder: root, expectedCohort: authority.membership.fingerprint,
                preparingChildrenOnly: true, beforeMemberDeletion: {
                    try await third.requestEnrollment(requestID: UUID(), label: "New participant")
                    try self.deliver(thirdRoot, to: f.root, writer: third.writerID)
                })
            XCTFail("New participant invalidates current preparation consent")
        } catch SharedLibraryOperationError.staleAuthority { }
        catch SharedLibraryRepositoryError.staleRevision { }
        let child = try await f.a.read(f.child)
        XCTAssertEqual(child.state.lifecycle, .alive, "No child deletion can be accepted under stale cohort consent")
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("Empty/Late.mp3")), f.audio)
    }
    func testChildPreparationDoesNotRenewChangedAudioHash() async throws {
        let f = try await fixture(), scope = try await prepared(f)
        _ = try await f.a.applyFolderDeletionScope(scope)
        let changed = Data("Unreviewed external audio".utf8), file = f.root.appendingPathComponent("Empty/Late.mp3")
        try changed.write(to: file, options: .atomic)
        let pending = try await f.a.reviewFolderOperation(id: f.folder.id), row = try XCTUnwrap(pending)
        do { _ = try await f.a.prepareReviewedFolderChildren(row); XCTFail("Updated child scope cannot authorize fresh hashes of unexpected audio") }
        catch SharedLibraryOperationError.contentChanged { }
        let child = try await f.a.read(f.child); XCTAssertEqual(child.state.lifecycle, .alive)
        XCTAssertEqual(try Data(contentsOf: file), changed)
    }
    func testChildPreparationPreservesLegacyAudioProvenance() async throws {
        let f = try await fixture(legacy: true), scope = try await prepared(f)
        let baseline = try await f.a.read(f.child)
        XCTAssertNil(baseline.state.value(for: "audioFingerprint"))
        XCTAssertEqual(try SharedRecordingMetadataAdapter.render(baseline).audioSHA256, SharedLibraryOperation.fingerprint(f.audio))
        _ = try await f.a.applyFolderDeletionScope(scope)
        let changed = Data("Unexpected replacement of bootstrapped audio".utf8), file = f.root.appendingPathComponent("Empty/Late.mp3")
        try changed.write(to: file, options: .atomic)
        let pending = try await f.a.reviewFolderOperation(id: f.folder.id), row = try XCTUnwrap(pending)
        do { _ = try await f.a.prepareReviewedFolderChildren(row); XCTFail("Legacy imported audio must retain its established hash during child deletion") }
        catch SharedLibraryOperationError.contentChanged { }
        let child = try await f.a.read(f.child)
        XCTAssertEqual(child.state.lifecycle, .alive)
        XCTAssertEqual(try SharedRecordingMetadataAdapter.render(child).audioSHA256, SharedLibraryOperation.fingerprint(f.audio))
        XCTAssertEqual(try Data(contentsOf: file), changed)
    }
    func testChildPreparationPreservesAcceptedMoveProvenanceWithoutMetadataHash() async throws {
        let f = try await fixture(legacy: true, legacyHasHash: false), scope = try await prepared(f)
        let baseline = try await f.a.read(f.child)
        XCTAssertNil(baseline.state.value(for: "audioFingerprint"))
        XCTAssertNil(try SharedRecordingMetadataAdapter.render(baseline).audioSHA256)
        XCTAssertFalse(try SharedPublishedLocations.fileIntents(state: baseline.state, library: baseline.libraryID).isEmpty)
        _ = try await f.a.applyFolderDeletionScope(scope)
        let changed = Data("Unexpected replacement after accepted legacy move".utf8), file = f.root.appendingPathComponent("Empty/Late.mp3")
        try changed.write(to: file, options: .atomic)
        let pending = try await f.a.reviewFolderOperation(id: f.folder.id), row = try XCTUnwrap(pending)
        do { _ = try await f.a.prepareReviewedFolderChildren(row); XCTFail("Accepted relocation hashes must survive child deletion preparation") }
        catch SharedLibraryOperationError.contentChanged { }
        let child = try await f.a.read(f.child); XCTAssertEqual(child.state.lifecycle, .alive)
        XCTAssertEqual(try Data(contentsOf: file), changed)
    }
    func testChildPreparationAcceptsUnchangedLegacyAudio() async throws {
        for hasHash in [true, false] {
            let f = try await fixture(legacy: true, legacyHasHash: hasHash), scope = try await prepared(f)
            _ = try await f.a.applyFolderDeletionScope(scope)
            let pending = try await f.a.reviewFolderOperation(id: f.folder.id)
            let outcome = try await f.a.prepareReviewedFolderChildren(XCTUnwrap(pending))
            XCTAssertEqual(outcome.result, .waitingForAcknowledgments)
            let child = try await f.a.read(f.child); XCTAssertEqual(child.state.lifecycle, .deleted)
            XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("Empty/Late.mp3")), f.audio)
        }
    }
    func testUpdatedScopeRefusesChildChangedDuringCommit() async throws {
        let f = try await fixture(), scope = try await prepared(f), before = try await f.a.read(f.folder)
        do {
            _ = try await f.a.applyFolderDeletionScope(scope, beforeCommit: {
                _ = try await f.a.edit(.init(base: try await f.a.read(f.child), changes: [.assign(field: "metadata.mode", value: .text("\"Mee\""))]))
            }); XCTFail("Child revision changed while consent was being committed")
        } catch SharedLibraryRepositoryError.staleRevision { }
        let after = try await f.a.read(f.folder); XCTAssertEqual(after.state, before.state)
        let child = try await f.a.read(f.child); XCTAssertEqual(child.state.lifecycle, .alive)
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("Empty/Late.mp3")), f.audio)
    }
    func testUpdatedScopeRefusesCopiedLibrary() async throws {
        let f = try await fixture(), scope = try await prepared(f)
        do { _ = try await f.b.applyFolderDeletionScope(scope); XCTFail("Identical persistent IDs do not make another root the reviewed library instance") }
        catch SharedLibraryCoordinatorError.differentBinding { }
        XCTAssertEqual(try Data(contentsOf: f.peerRoot.appendingPathComponent("Empty/Late.mp3")), f.audio)
    }
    private func addSecondChild(_ f: Fixture) async throws -> SharedEntityIdentity {
        let bytes = Data("Second synthetic conversation".utf8)
        _ = try await f.b.importAudio(bytes, entry: FileEntry(filename: "Second.hda", size: UInt32(bytes.count)), rawMD5: String(repeating: "0", count: 32))
        _ = try await f.b.relocateRecording(filename: "Second.mp3", toFolder: "Empty", changeFolder: true)
        let child = SharedEntityIdentity(id: try await f.b.reference(to: "Empty/Second.mp3").entityID, kind: .recording)
        try deliver(f.peerRoot, to: f.root, writer: f.b.writerID)
        try FileManager.default.copyItem(at: f.peerRoot.appendingPathComponent("Empty/Second.mp3"), to: f.root.appendingPathComponent("Empty/Second.mp3"))
        try Data(contentsOf: f.peerRoot.appendingPathComponent("library.json")).write(to: f.root.appendingPathComponent("library.json"), options: .atomic)
        return child
    }
    func testChildPreparationRefusesNewMemberAfterSavedScope() async throws {
        let f = try await fixture(), scope = try await prepared(f)
        _ = try await f.a.applyFolderDeletionScope(scope)
        let pending = try await f.a.reviewFolderOperation(id: f.folder.id), row = try XCTUnwrap(pending)
        let second = try await addSecondChild(f)
        let refused = try await f.a.prepareReviewedFolderChildren(row)
        XCTAssertEqual(refused.result, .needsReplanning)
        for child in [f.child, second] { let current = try await f.a.read(child); XCTAssertEqual(current.state.lifecycle, .alive) }
        let fresh = try await f.a.reviewFolderOperation(id: f.folder.id); XCTAssertTrue(fresh?.canReviewDeletionScope == true)
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("Empty/Late.mp3")), f.audio)
    }
    func testUpdatedScopePreservesAlreadyDeletedChildRecipe() async throws {
        let f = try await fixture(), first = try await prepared(f)
        _ = try await f.a.applyFolderDeletionScope(first)
        let pending = try await f.a.reviewFolderOperation(id: f.folder.id)
        _ = try await f.a.prepareReviewedFolderChildren(XCTUnwrap(pending))
        let deleted = try await f.a.read(f.child); XCTAssertEqual(deleted.state.lifecycle, .deleted)
        let second = try await addSecondChild(f), revised = try await prepared(f)
        XCTAssertEqual(Set(revised.members.map(\.path)), ["Empty/Late.mp3", "Empty/Second.mp3"])
        XCTAssertEqual(revised.members.first { $0.state.id == f.child.id }?.state.lifecycle, .deleted)
        _ = try await f.a.applyFolderDeletionScope(revised)
        let preserved = try await f.a.read(f.child), added = try await f.a.read(second)
        XCTAssertEqual(preserved.state, deleted.state, "Scope update cannot renew a child's original cleanup hashes, approval revision or lifecycle")
        XCTAssertEqual(added.state.lifecycle, .alive)
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("Empty/Late.mp3")), f.audio)
    }
    func testLateChildScopeUsesActualCaseSensitiveNamespace() async throws {
        guard let configured = ProcessInfo.processInfo.environment["DOCKTAPE_CASE_SENSITIVE_TEST_ROOT"] else { throw XCTSkip("Requires a disposable case-sensitive volume") }
        let root = URL(fileURLWithPath: configured)
        XCTAssertTrue((try root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])).volumeSupportsCaseSensitiveNames == true)
        let f = try await fixture(caseRoot: root), scope = try await prepared(f)
        _ = try await f.a.applyFolderDeletionScope(scope)
        let reviewed = try await f.a.reviewFolderOperation(id: f.folder.id)
        let result = try await f.a.prepareReviewedFolderChildren(XCTUnwrap(reviewed))
        XCTAssertEqual(result.result, .waitingForAcknowledgments)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("empty").path))
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("Empty/Late.mp3")), f.audio)
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
