// © 2026 High Gain Design. All rights reserved.
import XCTest
import Darwin
@testable import HiDockKit

final class SharedCompletedChildFolderTests: XCTestCase {
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
        let note: Data
    }
    private func fixture(caseRoot: URL? = nil) async throws -> Fixture {
        let parent = (caseRoot ?? FileManager.default.temporaryDirectory).appendingPathComponent(UUID().uuidString); roots.append(parent)
        let left = parent.appendingPathComponent("left"), right = parent.appendingPathComponent("right"), trash = parent.appendingPathComponent("synthetic-trash")
        try FileManager.default.createDirectory(at: left.appendingPathComponent("Folder"), withIntermediateDirectories: true)
        let audio = Data("Synthetic completed child conversation".utf8), note = Data("Preserve ordinary folder notes".utf8)
        try audio.write(to: left.appendingPathComponent("Folder/Clip.mp3"))
        try note.write(to: left.appendingPathComponent("Folder/.note"))
        try await TranscriptStore(baseDirectory: left).save(Transcript(recordingFilename: "Folder/Clip.mp3", transcriptionModel: "fixture", hasSpeakerLabels: false,
            segments: [.init(startTime: 0, endTime: 1, text: "Retain deleted transcript state")]), mp3Filename: "Folder/Clip.mp3")
        let syntheticTrash: @Sendable (URL) throws -> Void = { file in
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: file, to: trash.appendingPathComponent(UUID().uuidString + "-" + file.lastPathComponent))
        }
        let a = SharedLibraryCoordinator(root: left, writerID: UUID(), witnessDirectory: parent.appendingPathComponent("a-local"), trash: syntheticTrash)
        _ = try await a.enable(); _ = try await a.projectOutputs()
        let folders = try await a.snapshots(kinds: [.folder])
        let folder = SharedEntityIdentity(id: try XCTUnwrap(folders.first { $0.state.value(for: "name") == .text("Folder") }).state.id, kind: .folder)
        let child = SharedEntityIdentity(id: try await a.reference(to: "Folder/Clip.mp3").entityID, kind: .recording)
        try FileManager.default.copyItem(at: left, to: right)
        let b = SharedLibraryCoordinator(root: right, writerID: UUID(), witnessDirectory: parent.appendingPathComponent("b-local"), trash: syntheticTrash)
        try await b.requestEnrollment(requestID: UUID(), label: "Completed child peer")
        for _ in 0..<3 { try deliver(right, to: left, writer: b.writerID); try await a.refresh(); try deliver(left, to: right, writer: a.writerID); try await b.refresh() }
        return .init(root: left, peerRoot: right, a: a, b: b, folder: folder, child: child, audio: audio, note: note)
    }
    private func completeChild(_ f: Fixture) async throws {
        let pending = try await f.a.deleteSharedRecording(filename: "Folder/Clip.mp3")
        XCTAssertEqual(pending.result, .waitingForAcknowledgments)
        try deliver(f.root, to: f.peerRoot, writer: f.a.writerID)
        try Data(contentsOf: f.root.appendingPathComponent("library.json")).write(to: f.peerRoot.appendingPathComponent("library.json"), options: .atomic)
        let peer = try await f.b.reviewRecordingOperation(id: f.child.id), approval = try XCTUnwrap(peer)
        XCTAssertTrue(approval.canAcknowledge)
        try await f.b.acknowledgeReviewedRecordingOperation(approval)
        try deliver(f.peerRoot, to: f.root, writer: f.b.writerID)
        let completed = try await f.a.resumeRecordingOperation(id: f.child.id)
        XCTAssertEqual(completed.result, .complete); XCTAssertNil(completed.projectionError)
        for suffix in [".mp3", ".transcript.json", ".transcript.md", ".txt"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("Folder/Clip" + suffix).path))
        }
    }
    func testOrdinaryFolderRenameAfterChildCleanupPreservesTombstoneAndReceipt() async throws {
        let f = try await fixture(); try await completeChild(f)
        let childBefore = try await f.a.read(f.child)
        let receipt = f.root.deletingLastPathComponent().appendingPathComponent("a-local/Operations/" + childBefore.libraryID.uuidString + "/" + f.a.writerID.uuidString + "/" + f.child.id.uuidString + ".json")
        let bytes = try Data(contentsOf: receipt), progress = try SharedOperationReceipt.decode(bytes)
        XCTAssertEqual(progress.completed, progress.operation.steps.count); XCTAssertFalse(progress.attempting)
        print("Completed child folder phase: ordinary rename after actual approved Trash")
        let renamed = try await f.a.renameFolder(from: "Folder", to: "After")
        XCTAssertEqual(renamed.result, .complete); XCTAssertNil(renamed.projectionError); XCTAssertEqual(renamed.id, f.folder.id)
        guard renamed.result == .complete else { return }
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("After/.note")), f.note)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("Folder").path))
        let childAfter = try await f.a.read(f.child); XCTAssertEqual(childAfter.state, childBefore.state)
        XCTAssertEqual(try Data(contentsOf: receipt), bytes, "Moving an empty child slot cannot renew its completed cleanup")
        let restarted = SharedLibraryCoordinator(root: f.root, writerID: f.a.writerID, witnessDirectory: f.root.deletingLastPathComponent().appendingPathComponent("a-local"))
        let replay = try await restarted.resumeFolderOperation(id: f.folder.id)
        XCTAssertEqual(replay.result, .complete)
    }
    private func moveParentOnBothReplicas() async throws -> Fixture {
        let f = try await fixture(); try await completeChild(f)
        let renamed = try await f.a.renameFolder(from: "Folder", to: "After"); XCTAssertEqual(renamed.result, .complete)
        try deliver(f.root, to: f.peerRoot, writer: f.a.writerID)
        try Data(contentsOf: f.root.appendingPathComponent("library.json")).write(to: f.peerRoot.appendingPathComponent("library.json"), options: .atomic)
        let held = try await f.b.resumeFolderOperation(id: f.folder.id)
        XCTAssertEqual(held.result, .needsReplanning)
        XCTAssertEqual(try Data(contentsOf: f.peerRoot.appendingPathComponent("Folder/Clip.mp3")), f.audio)
        let cleanup = try await f.b.resumeRecordingOperation(id: f.child.id)
        XCTAssertEqual(cleanup.result, .complete); XCTAssertNotNil(cleanup.projectionError)
        do { _ = try await f.b.projectOutputs(); XCTFail("Current registry arrived before its canonical templates") }
        catch SharedProjectionWriteError.untracked(let path) { XCTAssertEqual(path, ".templates.json") }
        // Deliver the real current producer file after its registry. Physical
        // child cleanup was accepted; only publication waits for this arrival.
        try Data(contentsOf: f.root.appendingPathComponent(".templates.json")).write(to: f.peerRoot.appendingPathComponent(".templates.json"), options: .atomic)
        _ = try await f.b.projectOutputs()
        let moved = try await f.b.resumeFolderOperation(id: f.folder.id)
        XCTAssertEqual(moved.result, .complete); XCTAssertNil(moved.projectionError)
        XCTAssertEqual(try Data(contentsOf: f.peerRoot.appendingPathComponent("After/.note")), f.note)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.peerRoot.appendingPathComponent("Folder").path))
        return f
    }
    func testPeerRetainedOriginalsRequireIndependentCleanupBeforeParentMove() async throws {
        let f = try await moveParentOnBothReplicas()
        // One user removes the ordinary note; its provider removal reaches B.
        try FileManager.default.removeItem(at: f.root.appendingPathComponent("After/.note"))
        try FileManager.default.removeItem(at: f.peerRoot.appendingPathComponent("After/.note"))
        let deletion = try await f.a.deleteFolder(named: "After")
        XCTAssertEqual(deletion.result, .waitingForAcknowledgments)
        try deliver(f.root, to: f.peerRoot, writer: f.a.writerID)
        try Data(contentsOf: f.root.appendingPathComponent("library.json")).write(to: f.peerRoot.appendingPathComponent("library.json"), options: .atomic)
        try Data(contentsOf: f.root.appendingPathComponent(".templates.json")).write(to: f.peerRoot.appendingPathComponent(".templates.json"), options: .atomic)
        let rootReview = try await f.b.reviewFolderOperation(id: f.folder.id)
        try await f.b.acknowledgeReviewedFolderOperation(XCTUnwrap(rootReview))
        try deliver(f.peerRoot, to: f.root, writer: f.b.writerID)
        let deletedRoot = try await f.a.resumeFolderDeletion(id: f.folder.id)
        XCTAssertEqual(deletedRoot.result, .complete)
        let deletedPeer = try await f.b.resumeFolderDeletion(id: f.folder.id)
        XCTAssertEqual(deletedPeer.result, .complete)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("After").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.peerRoot.appendingPathComponent("After").path))
    }
    func testCompletedChildAllowsReviewedDestinationAfterCompetingFolderRename() async throws {
        let f = try await fixture(); try await completeChild(f)
        let first = try await f.a.renameFolder(from: "Folder", to: "After"); XCTAssertEqual(first.result, .complete)
        // B retains its original child. Its competing rename is accepted but
        // cannot physically relocate those still-pending original bytes.
        let competing = try await f.b.renameFolder(from: "Folder", to: "Peer")
        XCTAssertEqual(competing.result, .needsReplanning)
        try deliver(f.peerRoot, to: f.root, writer: f.b.writerID)
        let choices = try await f.a.folderPathChoices(f.a.read(f.folder))
        _ = try await f.a.resolveFolderPath(XCTUnwrap(choices.first { $0.destination == "Peer" }))
        let childBefore = try await f.a.read(f.child)
        let current = try await f.a.reviewFolderOperation(id: f.folder.id), row = try XCTUnwrap(current)
        XCTAssertTrue(row.canReplan)
        print("Completed child folder phase: reviewed changed destination")
        let plan = try await f.a.prepareFolderReplan(row)
        XCTAssertEqual(plan.source, "After"); XCTAssertEqual(plan.destination, "Peer")
        let applied = try await f.a.applyFolderReplan(plan)
        XCTAssertEqual(applied.result, .complete); XCTAssertNil(applied.projectionError)
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("Peer/.note")), f.note)
        let childAfter = try await f.a.read(f.child); XCTAssertEqual(childAfter.state, childBefore.state)
        XCTAssertEqual(try Data(contentsOf: f.peerRoot.appendingPathComponent("Folder/Clip.mp3")), f.audio)
    }
    func testCompletedChildHistoricalAncestorPlaceholderStopsParentMove() async throws {
        let f = try await fixture(); try await completedParent(f)
        try FileManager.default.removeItem(at: f.root.appendingPathComponent("Folder"))
        let placeholder = f.root.appendingPathComponent(".Folder.icloud"), bytes = Data("Synthetic directory placeholder".utf8)
        try bytes.write(to: placeholder)
        let moved = try await f.a.renameFolder(from: "After", to: "Third")
        XCTAssertEqual(moved.result, .needsReplanning)
        guard moved.result == .needsReplanning else { return }
        XCTAssertEqual(try Data(contentsOf: placeholder), bytes)
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("After/.note")), f.note)
    }
    func testParentDeletionRechecksCompletedChildReturnedOutsideCurrentDirectory() async throws {
        let f = try await moveParentOnBothReplicas()
        try FileManager.default.removeItem(at: f.root.appendingPathComponent("After/.note"))
        try FileManager.default.removeItem(at: f.peerRoot.appendingPathComponent("After/.note"))
        let returned = f.root.appendingPathComponent("Folder/Clip.mp3")
        try FileManager.default.createDirectory(at: returned.deletingLastPathComponent(), withIntermediateDirectories: true)
        try f.audio.write(to: returned)
        let deletion = try await f.a.deleteFolder(named: "After")
        if deletion.result == .waitingForAcknowledgments {
            try deliver(f.root, to: f.peerRoot, writer: f.a.writerID)
            try Data(contentsOf: f.root.appendingPathComponent("library.json")).write(to: f.peerRoot.appendingPathComponent("library.json"), options: .atomic)
            try Data(contentsOf: f.root.appendingPathComponent(".templates.json")).write(to: f.peerRoot.appendingPathComponent(".templates.json"), options: .atomic)
            let review = try await f.b.reviewFolderOperation(id: f.folder.id)
            try await f.b.acknowledgeReviewedFolderOperation(XCTUnwrap(review))
            try deliver(f.peerRoot, to: f.root, writer: f.b.writerID)
        }
        let childBefore = try await f.a.read(f.child)
        let held = try await f.a.resumeFolderDeletion(id: f.folder.id)
        XCTAssertEqual(held.result, .needsReplanning)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("After").path))
        XCTAssertEqual(try Data(contentsOf: returned), f.audio)
        let childAfter = try await f.a.read(f.child); XCTAssertEqual(childAfter.state, childBefore.state)
    }
    func testApprovedParentRemovalRechecksHistoricalAncestorAtFinalMutation() async throws {
        let f = try await moveParentOnBothReplicas()
        try FileManager.default.removeItem(at: f.root.appendingPathComponent("After/.note"))
        try FileManager.default.removeItem(at: f.peerRoot.appendingPathComponent("After/.note"))
        let pending = try await f.a.deleteFolder(named: "After")
        XCTAssertEqual(pending.result, .waitingForAcknowledgments)
        try deliver(f.root, to: f.peerRoot, writer: f.a.writerID)
        try Data(contentsOf: f.root.appendingPathComponent("library.json")).write(to: f.peerRoot.appendingPathComponent("library.json"), options: .atomic)
        try Data(contentsOf: f.root.appendingPathComponent(".templates.json")).write(to: f.peerRoot.appendingPathComponent(".templates.json"), options: .atomic)
        let review = try await f.b.reviewFolderOperation(id: f.folder.id)
        try await f.b.acknowledgeReviewedFolderOperation(XCTUnwrap(review))
        try deliver(f.peerRoot, to: f.root, writer: f.b.writerID)
        let permission = try await f.a.operationAuthority(entity: f.folder, paths: ["After"])
        XCTAssertTrue(permission.mayDestroy(.delete)); XCTAssertFalse(permission.hasLiveDescendants)
        XCTAssertTrue(try permission.validateLocalCommit())
        let placeholder = f.root.appendingPathComponent(".Folder.icloud"), bytes = Data("Synthetic late cloud directory".utf8)
        try bytes.write(to: placeholder)
        XCTAssertFalse(try permission.validateLocalCommit(), "Final physical permission must observe historical ancestor placeholders arriving after approval")
        let held = try await f.a.resumeFolderDeletion(id: f.folder.id)
        XCTAssertEqual(held.result, .needsReplanning)
        XCTAssertEqual(try Data(contentsOf: placeholder), bytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("After").path))
        // Actual provider completion restores absence; the original root
        // request may continue without issuing a new child deletion.
        try FileManager.default.removeItem(at: placeholder)
        let childBefore = try await f.a.read(f.child)
        let resumed = try await f.a.resumeFolderDeletion(id: f.folder.id)
        XCTAssertEqual(resumed.result, .complete)
        let childAfter = try await f.a.read(f.child); XCTAssertEqual(childAfter.state, childBefore.state)
    }
    func testReviewedParentMoveRechecksChildAliasOutsideAllReviewedDirectories() async throws {
        let f = try await moveParentOnBothReplicas()
        let left = try await f.a.renameFolder(from: "After", to: "Second")
        let right = try await f.b.renameFolder(from: "After", to: "Peer")
        XCTAssertEqual(left.result, .complete); XCTAssertEqual(right.result, .complete)
        try deliver(f.peerRoot, to: f.root, writer: f.b.writerID)
        let choices = try await f.a.folderPathChoices(f.a.read(f.folder))
        _ = try await f.a.resolveFolderPath(XCTUnwrap(choices.first { $0.destination == "Peer" }))
        let row = try await f.a.reviewFolderOperation(id: f.folder.id)
        let plan = try await f.a.prepareFolderReplan(XCTUnwrap(row))
        XCTAssertEqual(plan.source, "Second"); XCTAssertEqual(plan.destination, "Peer")
        XCTAssertFalse(plan.sourcePaths.contains("Folder"), "The old child's slot is outside the parent directories in this review")
        let child = try await f.a.read(f.child), parent = try await f.a.read(f.folder)
        let returned = f.root.appendingPathComponent("Folder/Clip.mp3")
        do {
            _ = try await f.a.applyFolderReplan(plan, beforeCommit: {
                try FileManager.default.createDirectory(at: returned.deletingLastPathComponent(), withIntermediateDirectories: true)
                try f.audio.write(to: returned)
            })
            XCTFail("A returning child alias must invalidate the reviewed physical move")
        } catch SharedLibraryOperationError.pathConflict(let path) { XCTAssertEqual(path, "Folder/Clip.mp3") }
        let childAfter = try await f.a.read(f.child), parentAfter = try await f.a.read(f.folder)
        XCTAssertEqual(childAfter.state, child.state); XCTAssertEqual(parentAfter.state, parent.state)
        XCTAssertEqual(try Data(contentsOf: returned), f.audio)
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("Second/.note")), f.note)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("Peer").path))
    }
    private func addPeerRecordingHistory(_ f: Fixture, archive: Bool = false) async throws {
        if archive { try await f.b.createSharedFolder(named: "Archive") }
        let moved = try await f.b.relocateRecording(filename: "Folder/Clip.mp3", toFolder: archive ? "Archive" : nil, changeFolder: true)
        XCTAssertEqual(moved.result, .complete)
        let returned = try await f.b.relocateRecording(filename: archive ? "Archive/Clip.mp3" : "Clip.mp3", toFolder: "Folder", changeFolder: true)
        XCTAssertEqual(returned.result, .complete)
        try deliver(f.peerRoot, to: f.root, writer: f.b.writerID)
        try Data(contentsOf: f.peerRoot.appendingPathComponent("library.json")).write(to: f.root.appendingPathComponent("library.json"), options: .atomic)
        for suffix in [".transcript.json", ".transcript.md", ".txt"] {
            let name = "Folder/Clip" + suffix
            try Data(contentsOf: f.peerRoot.appendingPathComponent(name)).write(to: f.root.appendingPathComponent(name), options: .atomic)
        }
        if archive { try FileManager.default.copyItem(at: f.peerRoot.appendingPathComponent("Archive"), to: f.root.appendingPathComponent("Archive")) }
    }
    func testAbsentPendingChildStillNeedsItsPeerApproval() async throws {
        let f = try await fixture()
        let pending = try await f.a.deleteSharedRecording(filename: "Folder/Clip.mp3")
        XCTAssertEqual(pending.result, .waitingForAcknowledgments)
        // Simulate provider/user removal, without claiming local Trash progress.
        for suffix in [".mp3", ".transcript.json", ".transcript.md", ".txt"] {
            try FileManager.default.removeItem(at: f.root.appendingPathComponent("Folder/Clip" + suffix))
        }
        let before = try await f.a.read(f.child)
        let rename = try await f.a.renameFolder(from: "Folder", to: "After")
        XCTAssertEqual(rename.result, .needsReplanning, "Absence alone cannot replace cohort approval")
        let after = try await f.a.read(f.child); XCTAssertEqual(after.state, before.state)
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("Folder/.note")), f.note)
    }
    func testAcknowledgedAbsenceDoesNotFabricateMissingChildReceipt() async throws {
        let f = try await fixture(); try await completeChild(f)
        let before = try await f.a.read(f.child)
        let receipt = f.root.deletingLastPathComponent().appendingPathComponent("a-local/Operations/" + before.libraryID.uuidString + "/" + f.a.writerID.uuidString + "/" + f.child.id.uuidString + ".json")
        try FileManager.default.removeItem(at: receipt)
        let rename = try await f.a.renameFolder(from: "Folder", to: "After")
        XCTAssertEqual(rename.result, .complete)
        XCTAssertFalse(FileManager.default.fileExists(atPath: receipt.path), "Provider absence is not fabricated local Trash progress")
        let after = try await f.a.read(f.child); XCTAssertEqual(after.state, before.state)
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("After/.note")), f.note)
    }
    func testChangedCohortCannotReuseCompletedChildApprovals() async throws {
        let f = try await fixture(); try await completeChild(f)
        let thirdRoot = f.root.deletingLastPathComponent().appendingPathComponent("third")
        try FileManager.default.copyItem(at: f.root, to: thirdRoot)
        let third = SharedLibraryCoordinator(root: thirdRoot, writerID: UUID(), witnessDirectory: f.root.deletingLastPathComponent().appendingPathComponent("third-local"))
        try await third.requestEnrollment(requestID: UUID(), label: "New cohort peer")
        for _ in 0..<4 {
            try deliver(thirdRoot, to: f.root, writer: third.writerID); try deliver(thirdRoot, to: f.peerRoot, writer: third.writerID)
            try await f.a.refresh(); try await f.b.refresh()
            try deliver(f.root, to: thirdRoot, writer: f.a.writerID); try deliver(f.root, to: f.peerRoot, writer: f.a.writerID)
            try deliver(f.peerRoot, to: thirdRoot, writer: f.b.writerID); try deliver(f.peerRoot, to: f.root, writer: f.b.writerID)
            try await third.refresh()
        }
        let permission = try await f.a.operationAuthority(entity: f.child, paths: [])
        XCTAssertEqual(permission.membership.cohort.count, 3); XCTAssertFalse(permission.mayDestroy(.delete))
        let rename = try await f.a.renameFolder(from: "Folder", to: "After")
        XCTAssertEqual(rename.result, .needsReplanning)
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("Folder/.note")), f.note)
    }
    func testAcquiredParentPermissionRechecksDeletedAliasBeforeMutation() async throws {
        let f = try await fixture(); try await completeChild(f)
        _ = try await f.a.renameFolder(from: "Folder", to: "After")
        let interrupted = SharedLibraryCoordinator(root: f.root, writerID: f.a.writerID, witnessDirectory: f.root.deletingLastPathComponent().appendingPathComponent("a-local"),
            afterCommit: { withUnsafeCurrentTask { $0?.cancel() } })
        do { _ = try await Task { try await interrupted.renameFolder(from: "After", to: "Third") }.value; XCTFail("Expected cancellation after actual accepted root intent") }
        catch is CancellationError { }
        let permission = try await f.a.operationAuthority(entity: f.folder, paths: ["After", "Third"])
        XCTAssertTrue(permission.directoryScopeMatches); XCTAssertTrue(try permission.validateLocalCommit())
        try FileManager.default.createDirectory(at: f.root.appendingPathComponent("Folder"), withIntermediateDirectories: true)
        let returned = f.root.appendingPathComponent("Folder/Clip.mp3"); try f.audio.write(to: returned)
        XCTAssertFalse(try permission.validateLocalCommit(), "Final coordinated mutation must recheck a child's alias outside the moved directory")
        let held = try await f.a.resumeFolderOperation(id: f.folder.id)
        XCTAssertEqual(held.result, .needsReplanning)
        XCTAssertEqual(try Data(contentsOf: returned), f.audio)
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("After/.note")), f.note)
    }
    func testCompletedChildUsesActualCaseSensitiveAliasNames() async throws {
        guard let configured = ProcessInfo.processInfo.environment["DOCKTAPE_CASE_SENSITIVE_TEST_ROOT"] else { throw XCTSkip("Requires owned case-sensitive APFS fixture") }
        let base = URL(fileURLWithPath: configured)
        XCTAssertTrue((try base.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])).volumeSupportsCaseSensitiveNames == true)
        let f = try await fixture(caseRoot: base); try await completedParent(f)
        let distinct = f.root.appendingPathComponent("Folder/clip.mp3"), bytes = Data("Distinct lowercase file".utf8)
        try bytes.write(to: distinct)
        let rename = try await f.a.renameFolder(from: "After", to: "Third")
        XCTAssertEqual(rename.result, .complete)
        XCTAssertEqual(try Data(contentsOf: distinct), bytes)
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("Third/.note")), f.note)
    }
    func testCompletedChildUsesActualCaseInsensitiveAliasNames() async throws {
        let f = try await fixture(); try await completedParent(f)
        XCTAssertFalse((try f.root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])).volumeSupportsCaseSensitiveNames == true)
        let returned = f.root.appendingPathComponent("Folder/clip.mp3"); try f.audio.write(to: returned)
        let rename = try await f.a.renameFolder(from: "After", to: "Third")
        XCTAssertEqual(rename.result, .needsReplanning)
        XCTAssertEqual(try Data(contentsOf: returned), f.audio)
    }
    private func completedParent(_ f: Fixture) async throws {
        try await completeChild(f)
        let renamed = try await f.a.renameFolder(from: "Folder", to: "After")
        XCTAssertEqual(renamed.result, .complete); XCTAssertNil(renamed.projectionError)
        try FileManager.default.createDirectory(at: f.root.appendingPathComponent("Folder"), withIntermediateDirectories: true)
        let history = try await f.a.operationAuthority(entity: f.child, paths: [])
        XCTAssertNotNil(history.recordingFileHistory["Folder/Clip.mp3"], "This is the child's current guarded Trash path, not a released old move")
    }
    func testCompletedChildMoveRefusesReturnedHistoricalPlaceholder() async throws {
        let f = try await fixture(); try await completedParent(f)
        let placeholder = f.root.appendingPathComponent("Folder/.Clip.mp3.icloud"), bytes = Data("Synthetic placeholder metadata".utf8)
        try bytes.write(to: placeholder)
        let rename = try await f.a.renameFolder(from: "After", to: "Third")
        XCTAssertEqual(rename.result, .needsReplanning)
        XCTAssertEqual(try Data(contentsOf: placeholder), bytes)
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("After/.note")), f.note)
    }
    func testCompletedChildMoveRefusesDanglingHistoricalAlias() async throws {
        let f = try await fixture(); try await completedParent(f)
        let alias = f.root.appendingPathComponent("Folder/Clip.mp3"), target = f.root.deletingLastPathComponent().appendingPathComponent("nonexistent-target")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        let rename = try await f.a.renameFolder(from: "After", to: "Third")
        XCTAssertEqual(rename.result, .needsReplanning, "A dangling entry is not proven absent")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: alias.path), target.path)
    }
    func testCompletedChildMoveRefusesUnreadableHistoricalParent() async throws {
        let f = try await fixture(); try await completedParent(f)
        let source = f.root.appendingPathComponent("Folder"), returned = source.appendingPathComponent("Clip.mp3")
        try f.audio.write(to: returned)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: source.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: source.path) }
        var info = stat()
        let status = returned.path.withCString { Darwin.lstat($0, &info) }, code = errno
        XCTAssertEqual(status, -1); XCTAssertEqual(code, EACCES)
        let rename = try await f.a.renameFolder(from: "After", to: "Third")
        XCTAssertEqual(rename.result, .needsReplanning, "An inaccessible alias is not proven absent")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: source.path)
        XCTAssertEqual(try Data(contentsOf: returned), f.audio)
    }
    func testCompletedChildMovePreservesReleasedCompletedHistory() async throws {
        let f = try await fixture(); try await addPeerRecordingHistory(f); try await completeChild(f)
        let history = try await f.a.operationAuthority(entity: f.child, paths: [])
        XCTAssertNil(history.recordingFileHistory["Clip.mp3"], "Registered completed relocation releases its former name")
        let unrelated = f.root.appendingPathComponent("Clip.mp3"), bytes = Data("New independent content in released filename".utf8)
        try bytes.write(to: unrelated)
        let rename = try await f.a.renameFolder(from: "Folder", to: "After")
        XCTAssertEqual(rename.result, .complete)
        XCTAssertEqual(try Data(contentsOf: unrelated), bytes)
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
