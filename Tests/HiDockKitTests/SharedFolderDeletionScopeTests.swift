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
        let syntheticTrash: @Sendable (URL) throws -> Void = { file in
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: file, to: trash.appendingPathComponent(UUID().uuidString + "-" + file.lastPathComponent))
        }
        let a = SharedLibraryCoordinator(root: left, writerID: UUID(), witnessDirectory: parent.appendingPathComponent("a-local"), trash: syntheticTrash)
        _ = try await a.enable(); _ = try await a.projectOutputs()
        let folders = try await a.snapshots(kinds: [.folder])
        let folder = SharedEntityIdentity(id: try XCTUnwrap(folders.first { $0.state.value(for: "name") == .text("Empty") }).state.id, kind: .folder)
        try FileManager.default.copyItem(at: left, to: right)
        let b = SharedLibraryCoordinator(root: right, writerID: UUID(), witnessDirectory: parent.appendingPathComponent("b-local"), trash: syntheticTrash)
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
    func testPeerCanReviewUpdatedScopeWithoutDiscardingCompletedRenameReceipt() async throws {
        let f = try await fixture()
        let before = try await f.b.read(f.folder)
        let receiptFile = f.peerRoot.deletingLastPathComponent().appendingPathComponent("b-local/Operations/" + before.libraryID.uuidString + "/" + f.b.writerID.uuidString + "/" + f.folder.id.uuidString + ".json")
        let receiptBytes = try Data(contentsOf: receiptFile), receipt = try SharedOperationReceipt.decode(receiptBytes)
        XCTAssertEqual(receipt.completed, receipt.operation.steps.count)
        try deliver(f.root, to: f.peerRoot, writer: f.a.writerID)
        let current = try await f.b.reviewFolderOperation(id: f.folder.id), row = try XCTUnwrap(current)
        XCTAssertTrue(row.canReviewDeletionScope)
        let scope = try await f.b.prepareFolderDeletionScope(row)
        XCTAssertEqual(scope.members.map(\.path), ["Empty/Late.mp3"])
        print("Peer cleanup phase: scope save")
        _ = try await f.b.applyFolderDeletionScope(scope)
        XCTAssertEqual(try Data(contentsOf: receiptFile), receiptBytes, "Saving an updated scope must preserve actual local rename progress")
        let permission = try await f.b.operationAuthority(entity: f.folder, paths: [])
        XCTAssertTrue(permission.approvedWriters(for: .delete).isEmpty)
        let child = try await f.b.read(f.child); XCTAssertEqual(child.state.lifecycle, .alive)
        XCTAssertEqual(try Data(contentsOf: f.peerRoot.appendingPathComponent("Empty/Late.mp3")), f.audio)
        let preparedRow = try await f.b.reviewFolderOperation(id: f.folder.id)
        XCTAssertTrue(preparedRow?.canPrepareChildren == true)
        print("Peer cleanup phase: child preparation")
        _ = try await f.b.prepareReviewedFolderChildren(XCTUnwrap(preparedRow))
        let deletedChild = try await f.b.read(f.child); XCTAssertEqual(deletedChild.state.lifecycle, .deleted)
        XCTAssertEqual(try Data(contentsOf: receiptFile), receiptBytes)
        let rootPermission = try await f.b.operationAuthority(entity: f.folder, paths: [])
        XCTAssertTrue(rootPermission.approvedWriters(for: .delete).isEmpty)
        try deliver(f.peerRoot, to: f.root, writer: f.b.writerID)
        print("Peer cleanup phase: other Mac child review")
        let firstChild = try await f.a.reviewRecordingOperation(id: f.child.id)
        try await f.a.acknowledgeReviewedRecordingOperation(XCTUnwrap(firstChild))
        try deliver(f.root, to: f.peerRoot, writer: f.a.writerID)
        print("Peer cleanup phase: child physical removal")
        let childRemoval = try await f.b.resumeRecordingOperation(id: f.child.id)
        XCTAssertEqual(childRemoval.result, .complete)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.peerRoot.appendingPathComponent("Empty/Late.mp3").path))
        print("Peer cleanup phase: cleanup preview")
        let pendingRoot = try await f.b.reviewFolderOperation(id: f.folder.id), cleanupRow = try XCTUnwrap(pendingRoot)
        XCTAssertTrue(cleanupRow.canReviewCleanupPlan)
        let cleanup = try await f.b.prepareFolderCleanupPlan(cleanupRow)
        XCTAssertEqual(cleanup.path, "Empty"); XCTAssertTrue(cleanup.retainedPaths.contains("Away"))
        print("Peer cleanup phase: cleanup save")
        _ = try await f.b.applyFolderCleanupPlan(cleanup)
        XCTAssertEqual(try Data(contentsOf: receiptFile), receiptBytes, "Review acceptance cannot discard the completed rename receipt")
        let afterCleanup = try await f.b.operationAuthority(entity: f.folder, paths: [])
        XCTAssertTrue(afterCleanup.approvedWriters(for: .delete).isEmpty)
        print("Peer cleanup phase: root owner approval")
        let saved = try await f.b.read(f.folder)
        guard case .document(let own)? = saved.state.value(for: SharedEntityState.fileIntentField(writer: f.b.writerID)) else { return XCTFail("Missing accepted cleanup lineage") }
        let intent = try JSONDecoder().decode(SharedAcceptedFileIntent.self, from: own.json)
        XCTAssertEqual(intent.replacesOperationID, receipt.operation.id)
        XCTAssertEqual(intent.inputRevision, receipt.operation.outputRevision)
        let resumed = SharedLibraryCoordinator(root: f.peerRoot, writerID: f.b.writerID,
            witnessDirectory: f.peerRoot.deletingLastPathComponent().appendingPathComponent("b-local"))
        let rootApproval = try await resumed.reviewFolderOperation(id: f.folder.id)
        try await resumed.acknowledgeReviewedFolderOperation(XCTUnwrap(rootApproval))
        try deliver(f.peerRoot, to: f.root, writer: f.b.writerID)
        print("Peer cleanup phase: other Mac root review")
        do { _ = try await f.a.reviewFolderOperation(id: f.folder.id); XCTFail("New producer state must wait for its canonical metadata delivery") }
        catch SharedProjectionWriteError.untracked(let file) { XCTAssertEqual(file, "library.json") }
        // Deliver the real current canonical metadata after its producer state.
        try Data(contentsOf: f.peerRoot.appendingPathComponent("library.json")).write(to: f.root.appendingPathComponent("library.json"), options: .atomic)
        let peerApproval = try await f.a.reviewFolderOperation(id: f.folder.id)
        try await f.a.acknowledgeReviewedFolderOperation(XCTUnwrap(peerApproval))
        try deliver(f.root, to: f.peerRoot, writer: f.a.writerID)
        let approvedRoot = try await resumed.reviewFolderOperation(id: f.folder.id), final = try XCTUnwrap(approvedRoot)
        XCTAssertTrue(final.canResume)
        let alias = f.peerRoot.appendingPathComponent("Away"), note = alias.appendingPathComponent(".unknown-note")
        try FileManager.default.createDirectory(at: alias, withIntermediateDirectories: true)
        let noteBytes = Data("Late unknown alias content".utf8); try noteBytes.write(to: note)
        print("Peer cleanup phase: late alias veto")
        let held = try await resumed.resumeReviewedFolderOperation(final)
        XCTAssertEqual(held.result, .needsReplanning)
        XCTAssertEqual(try Data(contentsOf: receiptFile), receiptBytes, "A returned alias must stop before completed rename progress is replaced")
        XCTAssertEqual(try Data(contentsOf: note), noteBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.peerRoot.appendingPathComponent("Empty").path))
        // Explicitly remove only the test's external alias; the app must never do so.
        try FileManager.default.removeItem(at: alias)
        let refreshed = try await resumed.reviewFolderOperation(id: f.folder.id)
        print("Peer cleanup phase: final root removal")
        let removed = try await resumed.resumeReviewedFolderOperation(XCTUnwrap(refreshed))
        XCTAssertEqual(removed.result, .complete)
        XCTAssertNil(removed.projectionError)
        let repeated = try await resumed.resumeFolderDeletion(id: f.folder.id)
        XCTAssertEqual(repeated.result, .complete)
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("Empty/Late.mp3")), f.audio, "Another Mac's retained original is not local cleanup progress")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.peerRoot.appendingPathComponent("Empty").path))
    }
    private func peerCleanupFixture() async throws -> (Fixture, SharedFolderCleanupReview) {
        let f = try await fixture()
        try deliver(f.root, to: f.peerRoot, writer: f.a.writerID)
        let pending = try await f.b.reviewFolderOperation(id: f.folder.id)
        let scope = try await f.b.prepareFolderDeletionScope(XCTUnwrap(pending))
        _ = try await f.b.applyFolderDeletionScope(scope)
        let prepared = try await f.b.reviewFolderOperation(id: f.folder.id)
        _ = try await f.b.prepareReviewedFolderChildren(XCTUnwrap(prepared))
        try deliver(f.peerRoot, to: f.root, writer: f.b.writerID)
        let approval = try await f.a.reviewRecordingOperation(id: f.child.id)
        try await f.a.acknowledgeReviewedRecordingOperation(XCTUnwrap(approval))
        try deliver(f.root, to: f.peerRoot, writer: f.a.writerID)
        let removed = try await f.b.resumeRecordingOperation(id: f.child.id)
        XCTAssertEqual(removed.result, .complete); XCTAssertNil(removed.projectionError)
        let current = try await f.b.reviewFolderOperation(id: f.folder.id)
        return (f, try await f.b.prepareFolderCleanupPlan(XCTUnwrap(current)))
    }
    func testPeerCleanupRejectsReceiptChangeAfterPreview() async throws {
        let (f, plan) = try await peerCleanupFixture(), before = try await f.b.read(f.folder)
        var receipt = try SharedOperationReceipt.decode(Data(contentsOf: plan.receiptFile))
        // Controlled checksum-valid receipt change, not a claim of physical progress.
        receipt.reviewedCleanups["synthetic-observation"] = String(repeating: "1", count: 64)
        let changed = try receipt.encoded(); try changed.write(to: plan.receiptFile, options: .atomic)
        do { _ = try await f.b.applyFolderCleanupPlan(plan); XCTFail("Reviewed receipt changed") }
        catch SharedLibraryCoordinatorError.staleReview { }
        let after = try await f.b.read(f.folder); XCTAssertEqual(after.state, before.state)
        XCTAssertEqual(try Data(contentsOf: plan.receiptFile), changed)
    }
    func testPeerCleanupRejectsAliasArrivingDuringCommit() async throws {
        let (f, plan) = try await peerCleanupFixture(), before = try await f.b.read(f.folder)
        let receipt = try Data(contentsOf: plan.receiptFile), alias = f.peerRoot.appendingPathComponent("Away")
        do {
            _ = try await f.b.applyFolderCleanupPlan(plan, beforeCommit: {
                try FileManager.default.createDirectory(at: alias, withIntermediateDirectories: true)
                try Data("Unknown returned directory".utf8).write(to: alias.appendingPathComponent(".note"))
            }); XCTFail("Late alias invalidates cleanup consent")
        } catch SharedLibraryOperationError.pathConflict(let path) { XCTAssertEqual(path, "Away") }
        let after = try await f.b.read(f.folder); XCTAssertEqual(after.state, before.state)
        XCTAssertEqual(try Data(contentsOf: plan.receiptFile), receipt)
        XCTAssertEqual(try Data(contentsOf: alias.appendingPathComponent(".note")), Data("Unknown returned directory".utf8))
    }
    func testPeerCleanupRejectsDirectoryChangeDuringCommit() async throws {
        let (f, plan) = try await peerCleanupFixture(), before = try await f.b.read(f.folder)
        let receipt = try Data(contentsOf: plan.receiptFile), note = f.peerRoot.appendingPathComponent("Empty/.note")
        do {
            _ = try await f.b.applyFolderCleanupPlan(plan, beforeCommit: { try Data("Unreviewed ordinary file".utf8).write(to: note) })
            XCTFail("Empty-directory proof changed")
        } catch SharedLibraryCoordinatorError.staleReview { }
        let after = try await f.b.read(f.folder); XCTAssertEqual(after.state, before.state)
        XCTAssertEqual(try Data(contentsOf: plan.receiptFile), receipt)
        XCTAssertEqual(try Data(contentsOf: note), Data("Unreviewed ordinary file".utf8))
    }
    func testPeerCleanupRejectsCopiedRoot() async throws {
        let (f, plan) = try await peerCleanupFixture()
        do { _ = try await f.a.applyFolderCleanupPlan(plan); XCTFail("Copied identities do not transfer consent") }
        catch SharedLibraryCoordinatorError.differentBinding { }
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.peerRoot.appendingPathComponent("Empty").path))
    }
    func testPeerCleanupRejectsCohortChangeDuringCommit() async throws {
        let (f, plan) = try await peerCleanupFixture(), before = try await f.b.read(f.folder)
        let thirdRoot = f.peerRoot.deletingLastPathComponent().appendingPathComponent("third")
        try FileManager.default.copyItem(at: f.peerRoot, to: thirdRoot)
        let third = SharedLibraryCoordinator(root: thirdRoot, writerID: UUID(), witnessDirectory: thirdRoot.deletingLastPathComponent().appendingPathComponent("third-local"))
        do {
            _ = try await f.b.applyFolderCleanupPlan(plan, beforeCommit: {
                try await third.requestEnrollment(requestID: UUID(), label: "Late participant")
                try self.deliver(thirdRoot, to: f.peerRoot, writer: third.writerID)
            }); XCTFail("Participating Macs changed")
        } catch SharedLibraryOperationError.staleAuthority { }
        catch SharedLibraryRepositoryError.staleRevision { }
        let after = try await f.b.read(f.folder); XCTAssertEqual(after.state, before.state)
    }
    func testPeerCleanupRejectsNewOwnershipClaimDuringCommit() async throws {
        let (f, plan) = try await peerCleanupFixture(), before = try await f.b.read(f.folder)
        let foreign = SharedLibraryCoordinator(root: f.root, writerID: f.a.writerID,
            witnessDirectory: f.root.deletingLastPathComponent().appendingPathComponent("a-local"),
            afterCommit: { withUnsafeCurrentTask { $0?.cancel() } })
        do {
            _ = try await f.b.applyFolderCleanupPlan(plan, beforeCommit: {
                // Cancel a genuine create after its semantic commit. Only a new
                // entity claim arrives; no old control file or directory is edited.
                let creation = Task { try await foreign.createSharedFolder(named: "Away") }
                do { try await creation.value; XCTFail("Creation must pause after its accepted state") }
                catch is CancellationError { }
                try self.deliver(f.root, to: f.peerRoot, writer: f.a.writerID)
            }); XCTFail("A new owner invalidates the full reviewed namespace")
        } catch SharedLibraryCoordinatorError.staleReview { }
        catch SharedLibraryRepositoryError.staleRevision { }
        catch SharedLibraryOperationError.staleAuthority { }
        let after = try await f.b.read(f.folder); XCTAssertEqual(after.state, before.state)
        let current = try await f.b.reviewFolderOperation(id: f.folder.id)
        let fresh = try await f.b.prepareFolderCleanupPlan(XCTUnwrap(current))
        XCTAssertFalse(fresh.retainedPaths.contains("Away"), "A fresh review preserves another folder's unique claim")
    }
    func testPeerCleanupUnreadableFileRefusesPreviewWithoutContentRead() async throws {
        let (f, plan) = try await peerCleanupFixture(), before = try await f.b.read(f.folder)
        let file = f.peerRoot.appendingPathComponent("Empty/.unreadable-note"), bytes = Data("Unrelated ordinary file".utf8)
        try bytes.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        let current = try await f.b.reviewFolderOperation(id: f.folder.id)
        do { _ = try await f.b.prepareFolderCleanupPlan(XCTUnwrap(current)); XCTFail("Nonempty root must refuse without opening its files") }
        catch SharedLibraryOperationError.unfinishedOperation { }
        let after = try await f.b.read(f.folder); XCTAssertEqual(after.state, before.state)
        XCTAssertEqual(try SharedLibraryOperation.fingerprint(Data(contentsOf: plan.receiptFile)), plan.receiptFingerprint)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }
    func testPeerCleanupUnreadableFileInvalidatesCommitWithoutContentRead() async throws {
        let (f, plan) = try await peerCleanupFixture(), before = try await f.b.read(f.folder)
        let file = f.peerRoot.appendingPathComponent("Empty/.unreadable-note"), bytes = Data("Late unreadable ordinary file".utf8)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        do {
            _ = try await f.b.applyFolderCleanupPlan(plan, beforeCommit: {
                try bytes.write(to: file)
                try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
            }); XCTFail("New ordinary file invalidates empty-directory consent without content reads")
        } catch SharedLibraryCoordinatorError.staleReview { }
        let after = try await f.b.read(f.folder); XCTAssertEqual(after.state, before.state)
        XCTAssertEqual(try SharedLibraryOperation.fingerprint(Data(contentsOf: plan.receiptFile)), plan.receiptFingerprint)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }
    func testPeerCleanupRejectsDirectoryReplacedByOutsideSymlink() async throws {
        let (f, plan) = try await peerCleanupFixture(), before = try await f.b.read(f.folder)
        let outside = f.peerRoot.deletingLastPathComponent().appendingPathComponent("outside-owned-fixture")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let note = outside.appendingPathComponent(".note"), bytes = Data("Outside the shared root".utf8)
        try bytes.write(to: note)
        let directory = f.peerRoot.appendingPathComponent("Empty")
        do {
            _ = try await f.b.applyFolderCleanupPlan(plan, beforeCommit: {
                try FileManager.default.removeItem(at: directory)
                try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: outside)
            }); XCTFail("A replacement symlink cannot satisfy empty-directory consent")
        } catch SharedLibraryOperationError.unsafePath { }
        let after = try await f.b.read(f.folder); XCTAssertEqual(after.state, before.state)
        XCTAssertEqual(try Data(contentsOf: note), bytes)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: directory.path), outside.path)
        XCTAssertEqual(try SharedLibraryOperation.fingerprint(Data(contentsOf: plan.receiptFile)), plan.receiptFingerprint)
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
