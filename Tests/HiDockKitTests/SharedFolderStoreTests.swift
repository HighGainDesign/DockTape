// © 2026 High Gain Design. All rights reserved.
import XCTest
@testable import HiDockKit

final class SharedFolderStoreTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() { for root in roots { try? FileManager.default.removeItem(at: root) } }
    private func fixture() async throws -> (URL, SharedLibraryCoordinator, RecordingStore) {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        roots.append(parent)
        let root = parent.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Folder/Nested"), withIntermediateDirectories: true)
        for name in ["Folder/A.mp3", "Folder/Nested/B.mp3"] { try Data(name.utf8).write(to: root.appendingPathComponent(name)) }
        try Data("keep hidden notes".utf8).write(to: root.appendingPathComponent("Folder/.notes"))
        try Data("keep unknown document".utf8).write(to: root.appendingPathComponent("Folder/Notes.txt"))
        let legacy = RecordingStore(baseDirectory: root)
        try await legacy.setup()
        try await legacy.setMeta(mode: "Mee", deviceFilename: "a.hda", for: "Folder/A.mp3")
        try await TranscriptStore(baseDirectory: root).save(Transcript(recordingFilename: "Folder/A.mp3", transcriptionModel: "fixture", hasSpeakerLabels: false,
            segments: [.init(startTime: 0, endTime: 1, text: "Preserve transcript")]), mp3Filename: "Folder/A.mp3")
        let coordinator = SharedLibraryCoordinator(root: root, writerID: UUID(), witnessDirectory: parent.appendingPathComponent("local"), trash: { url in
            let recycled = parent.appendingPathComponent("recycled")
            try FileManager.default.createDirectory(at: recycled, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: recycled.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent))
        })
        _ = try await coordinator.enable(); _ = try await coordinator.projectOutputs()
        let store = RecordingStore(baseDirectory: root, shared: SharedRecordingMetadataAdapter(coordinator: coordinator))
        try await store.setup()
        return (root, coordinator, store)
    }
    func testDistinctCaseSensitiveFolderReferencesRemainWritable() async throws {
        let configured = ProcessInfo.processInfo.environment["DOCKTAPE_CASE_SENSITIVE_TEST_ROOT"]
        let base = configured.map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        let parent = base.appendingPathComponent("DockTapeCaseFixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true); roots.append(parent)
        let sensitive = (try parent.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])).volumeSupportsCaseSensitiveNames == true
        if !sensitive {
            if configured != nil { XCTFail("Configured fixture volume must be case-sensitive"); return }
            throw XCTSkip("Run with DOCKTAPE_CASE_SENSITIVE_TEST_ROOT on a case-sensitive fixture volume")
        }
        let root = parent.appendingPathComponent("library")
        for name in ["Foo", "foo"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true) }
        for name in ["Meeting.mp3", "Other.mp3"] { try Data(name.utf8).write(to: root.appendingPathComponent(name)) }
        let missing = root.appendingPathComponent("Missing/Nested/file.json")
        XCTAssertTrue(SharedLibraryMaterializer.contained(missing, in: root))
        XCTAssertFalse(SharedLibraryMaterializer.contained(root, in: root))
        let outside = parent.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)
        XCTAssertFalse(SharedLibraryMaterializer.contained(root.appendingPathComponent("escape/Missing/file.json"), in: root))
        try FileManager.default.removeItem(at: root.appendingPathComponent("escape"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("broken"), withDestinationURL: outside.appendingPathComponent("MissingTarget"))
        XCTAssertFalse(SharedLibraryMaterializer.contained(root.appendingPathComponent("broken/file.json"), in: root))
        try FileManager.default.removeItem(at: root.appendingPathComponent("broken"))
        let a = SharedLibraryCoordinator(root: root, writerID: UUID(), witnessDirectory: parent.appendingPathComponent("local"), trash: { try FileManager.default.removeItem(at: $0) })
        _ = try await a.enable()
        _ = try await a.projectOutputs()
        let store = RecordingStore(baseDirectory: root, shared: SharedRecordingMetadataAdapter(coordinator: a)); try await store.setup()
        let catalog = await store.folderCatalog()
        let upper = try XCTUnwrap(catalog.references["Foo"]), lower = try XCTUnwrap(catalog.references["foo"])
        XCTAssertNotEqual(upper, lower)
        for (filename, folder, target) in [("Meeting.mp3", "Foo", upper), ("Other.mp3", "foo", lower)] {
            let reference = try await a.reference(to: filename)
            let into = try await a.relocateRecording(filename: filename, toFolder: folder, changeFolder: true, reference: reference, destinationReference: target)
            XCTAssertEqual(into.result, .complete, "Distinct case-sensitive destination remains writable")
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(folder + "/" + filename)), Data(filename.utf8))
            let back = try await a.relocateRecording(filename: folder + "/" + filename, changeFolder: true, reference: reference)
            XCTAssertEqual(back.result, .complete, "Distinct source ancestor remains writable")
        }
        let deleted = try await a.deleteFolder(named: "foo", reference: lower)
        XCTAssertEqual(deleted.result, .complete)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Foo").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("foo").path))
        let moved = try await a.renameFolder(from: "Foo", to: "Upper", reference: upper)
        XCTAssertEqual(moved.result, .complete)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Upper").path))
    }

    func testDisplayedFolderReferenceSurvivesRenameButRefusesAReusedName() async throws {
        let (root, a, store) = try await fixture()
        let before = await store.folderCatalog()
        let selected = try XCTUnwrap(before.references["Folder"])
        let moved = try await a.renameFolder(from: "Folder", to: "Moved", reference: selected)
        XCTAssertEqual(moved.result, .complete)
        try await a.createSharedFolder(named: "Folder")
        try await store.loadLibraryMeta()
        let current = await store.folderCatalog()
        XCTAssertEqual(current.references["Moved"], selected)
        XCTAssertNotEqual(current.references["Folder"], selected)
        for action in ["delete", "rename"] {
            do {
                if action == "delete" { _ = try await a.deleteFolder(named: "Folder", reference: selected) }
                else { _ = try await a.renameFolder(from: "Folder", to: "Unexpected", reference: selected) }
                XCTFail("Old selection cannot target the replacement")
            } catch SharedLibraryCoordinatorError.differentBinding {}
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Folder").path))
        }
        let (_, _, otherStore) = try await fixture()
        let otherCatalog = await otherStore.folderCatalog()
        let foreign = try XCTUnwrap(otherCatalog.references["Folder"])
        do { _ = try await a.deleteFolder(named: "Folder", reference: foreign); XCTFail("Different library must refuse") }
        catch SharedLibraryCoordinatorError.differentBinding {}
    }

    func testStoreFolderReferenceIsCapturedBeforeAwaitAndUnknownFolderHasNoAuthority() async throws {
        for action in ["delete", "rename"] {
            let (root, a, _) = try await fixture()
            let store = RecordingStore(baseDirectory: root, shared: SharedRecordingMetadataAdapter(coordinator: a), beforeSharedFileOperation: {
                _ = try? await a.renameFolder(from: "Folder", to: "Moved")
                try? await a.createSharedFolder(named: "Folder")
            })
            try await store.setup()
            do {
                if action == "delete" { try await store.deleteFolder(named: "Folder") }
                else { _ = try await store.renameFolder(from: "Folder", to: "Unexpected") }
                XCTFail("Store must retain the displayed ID across its awaited operation hook")
            } catch SharedLibraryCoordinatorError.differentBinding {}
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Folder").path))
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Moved/A.mp3")), Data("Folder/A.mp3".utf8))
        }
        let (root, a, store) = try await fixture()
        try await a.createSharedFolder(named: "Empty")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Unknown"), withIntermediateDirectories: true)
        try await store.loadLibraryMeta()
        let catalog = await store.folderCatalog()
        XCTAssertNotNil(catalog.references["Empty"], "An independently loaded empty folder needs its own stable reference")
        XCTAssertNil(catalog.references["Unknown"], "Raw directory presence cannot invent an entity selection")
        do { try await store.deleteFolder(named: "Unknown"); XCTFail("Reload/claim required for unknown folder") }
        catch SharedSidecarError.reloadRequired {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Unknown").path))
        let empty = try XCTUnwrap(catalog.references["Empty"])
        let view = try await a.read(.init(id: empty.entityID, kind: .folder))
        _ = try await a.edit(.init(base: view, changes: [.assign(field: "name", value: .text("Folder"))]))
        try await store.loadLibraryMeta()
        let ambiguous = await store.folderCatalog()
        XCTAssertNil(ambiguous.references["Folder"], "Two accepted identities at the same path grant no folder selection")
    }

    func testReviewedFolderDeletionCompletesOnlyAfterPeerApprovalAndProviderRemoval() async throws {
        let (left, a, _) = try await fixture()
        try await a.createSharedFolder(named: "Empty"); _ = try await a.projectOutputs()
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        roots.append(parent); try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let right = parent.appendingPathComponent("library")
        try FileManager.default.copyItem(at: left, to: right)
        let b = SharedLibraryCoordinator(root: right, writerID: UUID(), witnessDirectory: parent.appendingPathComponent("local"), trash: { try FileManager.default.removeItem(at: $0) })
        try await b.requestEnrollment(requestID: UUID(), label: "Folder peer")
        for _ in 0..<3 {
            try deliver(right, to: left, writer: b.writerID); try await a.refresh()
            try deliver(left, to: right, writer: a.writerID); try await b.refresh()
        }
        let pending = try await a.deleteFolder(named: "Empty")
        XCTAssertEqual(pending.result, .waitingForAcknowledgments)
        let first = try await a.reviewFolderOperation(id: pending.id)
        let owner = try XCTUnwrap(first)
        XCTAssertEqual(owner.waitingForMacs, ["Folder peer"])
        try deliver(left, to: right, writer: a.writerID); try await b.refresh()
        let observed = try await b.reviewFolderOperation(id: pending.id)
        let peer = try XCTUnwrap(observed)
        XCTAssertTrue(peer.canAcknowledge)
        let entity = SharedEntityIdentity(id: pending.id, kind: .folder)
        let before = try await b.read(entity)
        try await b.acknowledgeReviewedFolderOperation(peer)
        let after = try await b.read(entity)
        XCTAssertEqual(before.state, after.state, "Folder approval changes no semantic user data")
        XCTAssertTrue(FileManager.default.fileExists(atPath: right.appendingPathComponent("Empty").path))
        try deliver(right, to: left, writer: b.writerID)
        let currentOwner = try await a.reviewFolderOperation(id: pending.id)
        let current = try XCTUnwrap(currentOwner)
        XCTAssertTrue(current.canResume)
        let done = try await a.resumeReviewedFolderOperation(current)
        XCTAssertEqual(done.result, .complete)
        let ownerDone = try await a.reviewFolderOperation(id: pending.id)
        XCTAssertNil(ownerDone)
        try deliver(left, to: right, writer: a.writerID)
        try Data(contentsOf: left.appendingPathComponent("library.json")).write(to: right.appendingPathComponent("library.json"), options: .atomic)
        let peerPending = try await b.reviewFolderOperation(id: pending.id)
        XCTAssertNotNil(peerPending, "Metadata-only arrival cannot hide a retained folder")
        try FileManager.default.removeItem(at: right.appendingPathComponent("Empty"))
        let peerDone = try await b.reviewFolderOperation(id: pending.id)
        XCTAssertNil(peerDone, "Exact acknowledged provider removal clears the pending folder")
    }

    func testFolderReviewDoesNotHideCompletedMetadataWithBothPathsOrChangedDestination() async throws {
        for changed in [false, true] {
            let (root, a, _) = try await fixture()
            let outcome = try await a.renameFolder(from: "Folder", to: "Renamed")
            XCTAssertEqual(outcome.result, .complete)
            if changed {
                try Data("externally changed audio".utf8).write(to: root.appendingPathComponent("Renamed/A.mp3"))
            } else {
                try FileManager.default.createDirectory(at: root.appendingPathComponent("Folder"), withIntermediateDirectories: true)
                try Data("late original".utf8).write(to: root.appendingPathComponent("Folder/Late.mp3"))
            }
            let row = try await a.reviewFolderOperation(id: outcome.id)
            XCTAssertNotNil(row, "Completed metadata cannot hide remaining source or changed destination files")
            if let row { XCTAssertFalse(row.canResume, "Conflicting paths need explicit review before moving anything") }
        }
    }

    func testCompletedFolderMoveDoesNotReturnAfterAcceptedChildChanges() async throws {
        for change in ["moveIn", "moveOut", "delete"] {
            let (_, a, _) = try await fixture()
            let outcome = try await a.renameFolder(from: "Folder", to: "Renamed")
            XCTAssertEqual(outcome.result, .complete)
            switch change {
            case "moveIn":
                let moved = try await a.relocateRecording(filename: "Renamed/Nested/B.mp3", toFolder: "Renamed", changeFolder: true)
                XCTAssertEqual(moved.result, .complete)
            case "moveOut":
                let moved = try await a.relocateRecording(filename: "Renamed/A.mp3", changeFolder: true)
                XCTAssertEqual(moved.result, .complete)
            default:
                let deleted = try await a.deleteSharedRecording(filename: "Renamed/A.mp3")
                XCTAssertEqual(deleted.result, .complete)
            }
            let row = try await a.reviewFolderOperation(id: outcome.id)
            XCTAssertTrue(row == nil, "Accepted child \(change) cannot revive a completed directory move")
        }
    }

    func testFolderReviewOffersRecoveryWhenCompletedMetadataArrivesBeforeDirectoryMove() async throws {
        let (left, a, _) = try await fixture()
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        roots.append(parent); try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let right = parent.appendingPathComponent("library")
        try FileManager.default.copyItem(at: left, to: right)
        let b = SharedLibraryCoordinator(root: right, writerID: UUID(), witnessDirectory: parent.appendingPathComponent("local"))
        try await b.requestEnrollment(requestID: UUID(), label: "Folder peer")
        for _ in 0..<3 {
            try deliver(right, to: left, writer: b.writerID); try await a.refresh()
            try deliver(left, to: right, writer: a.writerID); try await b.refresh()
        }
        let original = try Data(contentsOf: right.appendingPathComponent("Folder/A.mp3"))
        let outcome = try await a.renameFolder(from: "Folder", to: "Renamed")
        XCTAssertEqual(outcome.result, .complete)
        try deliver(left, to: right, writer: a.writerID)
        try Data(contentsOf: left.appendingPathComponent("library.json")).write(to: right.appendingPathComponent("library.json"), options: .atomic)
        let observed = try await b.reviewFolderOperation(id: outcome.id)
        let row = try XCTUnwrap(observed)
        XCTAssertTrue(row.canResume, "Original accepted inventory needs a usable exact recovery after metadata-first arrival")
        if row.canResume {
            let resumed = try await b.resumeReviewedFolderOperation(row)
            XCTAssertEqual(resumed.result, .complete)
            XCTAssertFalse(FileManager.default.fileExists(atPath: right.appendingPathComponent("Folder").path))
            XCTAssertEqual(try Data(contentsOf: right.appendingPathComponent("Renamed/A.mp3")), original)
            let finished = try await b.reviewFolderOperation(id: outcome.id)
            XCTAssertNil(finished)
        }
    }

    func testFolderPeerReceiptSurvivesFinalMetadataWithoutLosingMoveEvidence() async throws {
        enum Stopped: Error { case afterMove }
        for attempted in [false, true] {
            let (left, a, _) = try await fixture()
            let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            roots.append(parent); try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let right = parent.appendingPathComponent("library")
            try FileManager.default.copyItem(at: left, to: right)
            let local = parent.appendingPathComponent("local")
            let b = SharedLibraryCoordinator(root: right, writerID: UUID(), witnessDirectory: local)
            try await b.requestEnrollment(requestID: UUID(), label: "Folder peer")
            for _ in 0..<3 {
                try deliver(right, to: left, writer: b.writerID); try await a.refresh()
                try deliver(left, to: right, writer: a.writerID); try await b.refresh()
            }
            let folder = try await a.snapshots(kinds: [.folder]).first { $0.state.value(for: "name") == .text("Folder") }
            let id = try XCTUnwrap(folder?.state.id)
            let reference = try await b.reference(to: "Folder/A.mp3")
            let token = attempted ? nil : try await b.pinJob(.init(id: reference.entityID, kind: .recording), audioURL: right.appendingPathComponent("Folder/A.mp3"))
            do { _ = try await a.renameFolder(from: "Folder", to: "Renamed", afterMutation: { _ in throw Stopped.afterMove }); XCTFail() }
            catch Stopped.afterMove {}
            try deliver(left, to: right, writer: a.writerID)
            if attempted {
                // Public legacy resume can reconstruct the selected peer intent.
                do { _ = try await b.resumeFolderOperation(id: id, afterMutation: { _ in throw Stopped.afterMove }); XCTFail() }
                catch Stopped.afterMove {}
            } else {
                let observed = try await b.reviewFolderOperation(id: id)
                let row = try XCTUnwrap(observed)
                let operation = try XCTUnwrap(row.operation)
                let receipts = local.appendingPathComponent("Operations/" + row.base.libraryID.uuidString + "/" + b.writerID.uuidString)
                let pending = SharedLibraryMaterializer(root: right, receipts: receipts, authority: {
                    try await b.operationAuthority(entity: operation.entity, paths: Array(operation.canonicalPaths))
                })
                let waiting = try await pending.replay(operation)
                XCTAssertEqual(waiting, .waitingForActiveWork)
                if let token { await b.finishJob(token) }
            }
            let finished = try await a.resumeFolderOperation(id: id)
            XCTAssertEqual(finished.result, .complete)
            try deliver(left, to: right, writer: a.writerID)
            try Data(contentsOf: left.appendingPathComponent("library.json")).write(to: right.appendingPathComponent("library.json"), options: .atomic)
            let observed = try await b.reviewFolderOperation(id: id)
            let row = try XCTUnwrap(observed)
            XCTAssertTrue(row.canResume)
            let receiptFile = local.appendingPathComponent("Operations/" + row.base.libraryID.uuidString + "/" + b.writerID.uuidString + "/" + id.uuidString + ".json")
            var saved = try SharedOperationReceipt.decode(Data(contentsOf: receiptFile))
            saved.reviewedCleanups["preserve unrelated receipt evidence"] = "synthetic witness"
            try saved.encoded().write(to: receiptFile, options: .atomic)
            let result = try await b.resumeReviewedFolderOperation(row)
            let completed = try SharedOperationReceipt.decode(Data(contentsOf: receiptFile))
            var expected = saved
            expected.operation.outputRevision = completed.operation.outputRevision
            expected.completed = completed.completed; expected.attempting = completed.attempting
            XCTAssertEqual(try expected.encoded(), try completed.encoded(), "Recovery changes only output authority and actual replay phase, preserving all original receipt evidence")
            XCTAssertEqual(result.result, .complete, "Final metadata may update output authority without discarding the same original plan or attempted phase")
            XCTAssertEqual(try Data(contentsOf: right.appendingPathComponent("Renamed/A.mp3")), Data("Folder/A.mp3".utf8))
        }
    }

    func testFolderResumeKeepsReviewedStateAndCohortThroughFinalRemoval() async throws {
        for change in ["cohort", "state"] {
            let (root, a, _) = try await fixture()
            try await a.createSharedFolder(named: "Empty"); _ = try await a.projectOutputs()
            let interrupted = SharedLibraryCoordinator(root: root, writerID: a.writerID,
                witnessDirectory: root.deletingLastPathComponent().appendingPathComponent("local"),
                afterCommit: { withUnsafeCurrentTask { $0?.cancel() } })
            let task = Task { try await interrupted.deleteFolder(named: "Empty") }
            do { _ = try await task.value; XCTFail("Expected exit after durable request") } catch is CancellationError {}
            let folders = try await a.snapshots(kinds: [.folder])
            let folder = try XCTUnwrap(folders.first { $0.state.value(for: "name") == .text("Empty") })
            let current = try await a.reviewFolderOperation(id: folder.state.id)
            let review = try XCTUnwrap(current)
            XCTAssertTrue(review.canResume)
            let late = SharedLibraryCoordinator(root: root, writerID: UUID(), witnessDirectory: root.deletingLastPathComponent().appendingPathComponent("late-local"))
            do {
                _ = try await a.resumeFolderDeletion(id: folder.state.id, reviewedFolder: review.base, expectedCohort: review.cohort, beforeFinalRemoval: {
                    if change == "cohort" { try await late.requestEnrollment(requestID: UUID(), label: "Late Mac") }
                    else {
                        let entity = SharedEntityIdentity(id: folder.state.id, kind: .folder)
                        _ = try await a.edit(.init(base: try await a.read(entity), changes: [.assign(field: "description", value: .text("Changed after review"))]))
                    }
                })
                XCTFail("A late reviewed-state or cohort change must stop removal")
            } catch {
                XCTAssertTrue(error as? SharedLibraryOperationError == .staleAuthority || error as? SharedLibraryCoordinatorError == .staleReview, "Expected exact-review refusal, got \(error)")
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Empty").path), "Refusal preserves the original folder")
        }
    }

    func testFolderDeletionRefusesMemberMoveAndPathReuseAfterRequestValidation() async throws {
        let (root, a, _) = try await fixture()
        let folder = try await a.snapshots(kinds: [.folder]).first { $0.state.value(for: "name") == .text("Folder") }
        let folderID = try XCTUnwrap(folder?.state.id)
        let original = try await a.recording(at: "Folder/A.mp3")
        let replacement = SharedEntityIdentity(id: UUID(), kind: .recording)
        let interrupted = SharedLibraryCoordinator(root: root, writerID: a.writerID,
            witnessDirectory: root.deletingLastPathComponent().appendingPathComponent("local"),
            afterCommit: { withUnsafeCurrentTask { $0?.cancel() } })
        let task = Task { try await interrupted.deleteFolder(named: "Folder") }
        do { _ = try await task.value; XCTFail() } catch is CancellationError {}
        let before = Data("new recording at reused path".utf8)
        let originalBytes = try Data(contentsOf: root.appendingPathComponent("Folder/A.mp3"))
        let once = CommitCounter()
        do {
            _ = try await a.resumeFolderDeletion(id: folderID, beforeMemberDeletion: {
                if await once.next() == 1 {
                    let moved = try await a.relocateRecording(filename: "Folder/A.mp3", title: "Moved", changeFolder: true)
                    guard moved.result == .complete else { throw SharedLibraryOperationError.unfinishedOperation }
                    try before.write(to: root.appendingPathComponent("Folder/A.mp3"))
                    _ = try await a.edit(.init(base: try await a.read(replacement), changes: [
                        .assign(field: "initialPath", value: .text("Folder/A.mp3")), .assign(field: "title", value: .text("A")),
                        .assign(field: "folder", value: .text(folderID.uuidString))]))
                }
            })
            XCTFail("An accepted folder request cannot target a newly reused path")
        } catch {
            XCTAssertTrue(error as? SharedLibraryCoordinatorError == .staleReview || error as? SharedLibraryCoordinatorError == .differentBinding, "Expected requested-member refusal, got \(error)")
        }
        let kept = try await a.read(replacement)
        XCTAssertEqual(kept.state.lifecycle, .alive, "Unrequested replacement must not be deleted")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Folder/A.mp3")), before)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Moved.mp3")), originalBytes)
    }

    private actor CommitCounter {
        var value = 0
        func next() -> Int { value += 1; return value }
    }
    func testFinalEmptyFolderRemovalKeepsOriginalGuardAcrossMissingReceipt() async throws {
        for change in ["maintenance", "ABA", "missingProof"] {
            let (root, original, _) = try await fixture()
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Empty"), withIntermediateDirectories: true)
            let extra = root.deletingLastPathComponent().appendingPathComponent("empty-library")
            try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
            let local = extra.deletingLastPathComponent().appendingPathComponent("empty-local")
            let coordinator = SharedLibraryCoordinator(root: extra, writerID: original.writerID, witnessDirectory: local)
            _ = try await coordinator.enable(); try await coordinator.createSharedFolder(named: "Empty")
            _ = try await coordinator.projectOutputs()
            let folders = try await coordinator.snapshots(kinds: [.folder])
            let folder = try XCTUnwrap(folders.first)
            let entity = SharedEntityIdentity(id: folder.state.id, kind: .folder)
            let counter = CommitCounter()
            let interrupted = SharedLibraryCoordinator(root: extra, writerID: coordinator.writerID, witnessDirectory: local,
                afterCommit: { if await counter.next() == 2 { withUnsafeCurrentTask { $0?.cancel() } } })
            let task = Task { try await interrupted.deleteFolder(named: "Empty") }
            do { _ = try await task.value; XCTFail("Cancel final accepted removal") } catch is CancellationError {}
            XCTAssertTrue(FileManager.default.fileExists(atPath: extra.appendingPathComponent("Empty").path))
            let receipt = local.appendingPathComponent("Operations").appendingPathComponent(folder.libraryID.uuidString)
                .appendingPathComponent(coordinator.writerID.uuidString).appendingPathComponent(entity.id.uuidString + ".json")
            if FileManager.default.fileExists(atPath: receipt.path) { try FileManager.default.removeItem(at: receipt) }
            var current = try await coordinator.read(entity)
            XCTAssertEqual(current.state.lifecycle, .deleted)
            if change == "maintenance" { try await coordinator.refresh() }
            else {
                current = try await coordinator.edit(.init(base: current, changes: [.restore]))
                var changes: [SharedLibraryMutation] = []
                if change == "missingProof" { changes.append(.assign(field: "materialization.files." + coordinator.writerID.uuidString.lowercased(), value: .unset)) }
                changes.append(.delete)
                _ = try await coordinator.edit(.init(base: current, changes: changes))
            }
            let result = try await coordinator.resumeFolderDeletion(id: entity.id)
            XCTAssertEqual(result.result, change == "maintenance" ? .complete : .needsReplanning, change)
            XCTAssertEqual(FileManager.default.fileExists(atPath: extra.appendingPathComponent("Empty").path), change != "maintenance", change)
        }
    }

    func testLegacyBootstrapPreservesEmptyAndNonAudioFolders() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        roots.append(parent)
        let root = parent.appendingPathComponent("library")
        for path in ["Empty", "Empty/Nested", "Notes", ".private"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        try Data("ordinary notes".utf8).write(to: root.appendingPathComponent("Notes/readme.txt"))
        let coordinator = SharedLibraryCoordinator(root: root, writerID: UUID(), witnessDirectory: parent.appendingPathComponent("local"))
        _ = try await coordinator.enable()
        let views = try await coordinator.snapshots(kinds: [.folder])
        XCTAssertEqual(Set(views.compactMap { $0.state.value(for: "initialPath").flatMap { if case .text(let path) = $0 { return path }; return nil } }), ["Empty", "Empty/Nested", "Notes"])
        _ = try await coordinator.projectOutputs()
        let reopened = SharedLibraryCoordinator(root: root, writerID: coordinator.writerID, witnessDirectory: parent.appendingPathComponent("local"))
        let restored = try await reopened.snapshots(kinds: [.folder])
        XCTAssertEqual(Set(restored.map(\.state.id)), Set(views.map(\.state.id)))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Notes/readme.txt")), Data("ordinary notes".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Empty/Nested").path))
    }

    func testActualSharedFolderRenamePreservesDescendantIDsAndEveryFile() async throws {
        let (root, coordinator, store) = try await fixture()
        let a = try await coordinator.reference(to: "Folder/A.mp3")
        let b = try await coordinator.reference(to: "Folder/Nested/B.mp3")
        let name = try await store.renameFolder(from: "Folder", to: "Renamed")
        XCTAssertEqual(name, "Renamed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Folder").path))
        let currentA = try await coordinator.reference(to: "Renamed/A.mp3")
        let currentB = try await coordinator.reference(to: "Renamed/Nested/B.mp3")
        XCTAssertEqual(a, currentA); XCTAssertEqual(b, currentB)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Renamed/.notes")), Data("keep hidden notes".utf8))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Renamed/Notes.txt")), Data("keep unknown document".utf8))
        let transcript = try SharedContentCoding.decoder().decode(Transcript.self, from: Data(contentsOf: root.appendingPathComponent("Renamed/A.transcript.json")))
        XCTAssertEqual(transcript.recordingFilename, "Renamed/A.mp3")
        let recordings = await store.allRecordings()
        XCTAssertEqual(Set(recordings.map(\.filename)), ["Renamed/A.mp3", "Renamed/Nested/B.mp3"])
        XCTAssertTrue(recordings.allSatisfy { $0.reference != nil })
    }
    func testFolderDestinationCollisionPreservesSourceAndLogicalName() async throws {
        let (root, coordinator, store) = try await fixture()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Occupied"), withIntermediateDirectories: true)
        try Data("unrelated".utf8).write(to: root.appendingPathComponent("Occupied/other.txt"))
        do { _ = try await store.renameFolder(from: "Folder", to: "Occupied"); XCTFail("Do not overwrite destination") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Folder/A.mp3").path))
        let folders = try await coordinator.snapshots(kinds: [.folder])
        XCTAssertTrue(folders.contains { $0.state.value(for: "name") == .text("Folder") })
    }
    func testChildWorkFromAnotherInstanceDelaysWholeFolderMoveAndResumes() async throws {
        let (root, holder, _) = try await fixture()
        let reference = try await holder.reference(to: "Folder/Nested/B.mp3")
        let token = try await holder.pinJob(.init(id: reference.entityID, kind: .recording), audioURL: root.appendingPathComponent("Folder/Nested/B.mp3"))
        let observer = SharedLibraryCoordinator(root: root, writerID: holder.writerID, witnessDirectory: root.deletingLastPathComponent().appendingPathComponent("local"))
        let pending = try await observer.renameFolder(from: "Folder", to: "Renamed")
        XCTAssertEqual(pending.result, .waitingForActiveWork)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Folder/Nested/B.mp3").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Renamed").path))
        await holder.finishJob(token)
        let reopened = SharedLibraryCoordinator(root: root, writerID: holder.writerID, witnessDirectory: root.deletingLastPathComponent().appendingPathComponent("local"))
        let complete = try await reopened.resumeFolderOperation(id: pending.id)
        XCTAssertEqual(complete.result, .complete)
        XCTAssertNil(complete.projectionError)
        let current = try await reopened.resolve(reference)
        XCTAssertEqual(current, "Renamed/Nested/B.mp3")
    }
    func testChildPlacementChangeWhileParentMoveWaitsRequiresReplanning() async throws {
        for scenario in ["rename", "reparent", "delete", "newChild"] {
            let (root, coordinator, _) = try await fixture()
            let ref = try await coordinator.reference(to: "Folder/A.mp3")
            let nested = try await coordinator.reference(to: "Folder/Nested/B.mp3")
            let token = try await coordinator.pinJob(.init(id: nested.entityID, kind: .recording), audioURL: root.appendingPathComponent("Folder/Nested/B.mp3"))
            let pending = try await coordinator.renameFolder(from: "Folder", to: "Renamed")
            XCTAssertEqual(pending.result, .waitingForActiveWork)
            let child = SharedEntityIdentity(id: ref.entityID, kind: .recording)
            switch scenario {
            case "delete":
                _ = try await coordinator.edit(.init(base: try await coordinator.read(child), changes: [.delete]))
            case "newChild":
                let fresh = SharedEntityIdentity(id: UUID(), kind: .recording)
                _ = try await coordinator.edit(.init(base: try await coordinator.read(fresh), changes: [
                    .assign(field: "initialPath", value: .text("Folder/Late.mp3")), .assign(field: "title", value: .text("Late")),
                    .assign(field: "folder", value: .text(pending.id.uuidString))]))
            default:
                _ = try await coordinator.edit(.init(base: try await coordinator.read(child), changes: [
                    .assign(field: scenario == "rename" ? "title" : "folder", value: scenario == "rename" ? .text("Changed") : .unset)]))
            }
            await coordinator.finishJob(token)
            let reopened = SharedLibraryCoordinator(root: root, writerID: coordinator.writerID, witnessDirectory: root.deletingLastPathComponent().appendingPathComponent("local"))
            let resumed = try await reopened.resumeFolderOperation(id: pending.id)
            XCTAssertEqual(resumed.result, .needsReplanning, "Changed child placement must invalidate the directory plan")
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Folder/A.mp3").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Renamed").path))
        }
    }

    func testIndependentMetadataEditWhileParentMoveWaitsIsRetained() async throws {
        let (root, coordinator, _) = try await fixture()
        let ref = try await coordinator.reference(to: "Folder/A.mp3")
        let token = try await coordinator.pinJob(.init(id: ref.entityID, kind: .recording), audioURL: root.appendingPathComponent("Folder/A.mp3"))
        let pending = try await coordinator.renameFolder(from: "Folder", to: "Renamed")
        XCTAssertEqual(pending.result, .waitingForActiveWork)
        let child = SharedEntityIdentity(id: ref.entityID, kind: .recording)
        _ = try await coordinator.edit(.init(base: try await coordinator.read(child), changes: [.assign(field: "metadata.mode", value: .text("\"Wip\""))]))
        await coordinator.finishJob(token)
        let reopened = SharedLibraryCoordinator(root: root, writerID: coordinator.writerID, witnessDirectory: root.deletingLastPathComponent().appendingPathComponent("local"))
        let resumed = try await reopened.resumeFolderOperation(id: pending.id)
        XCTAssertEqual(resumed.result, .complete)
        XCTAssertNil(resumed.projectionError)
        let view = try await reopened.read(child)
        XCTAssertEqual(view.state.value(for: "metadata.mode"), .text("\"Wip\""))
        let current = try await reopened.resolve(ref)
        XCTAssertEqual(current, "Renamed/A.mp3")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(current).path))
    }

    func testInterruptedDirectoryMoveDoesNotPublishSidecarsBeforeReceiptRecovery() async throws {
        enum Stopped: Error { case afterMove }
        let (root, coordinator, _) = try await fixture()
        let folders = try await coordinator.snapshots(kinds: [.folder])
        let id = try XCTUnwrap(folders.first { $0.state.value(for: "name") == .text("Folder") }?.state.id)
        do { _ = try await coordinator.renameFolder(from: "Folder", to: "Renamed", afterMutation: { _ in throw Stopped.afterMove }); XCTFail() }
        catch Stopped.afterMove {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Folder").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Renamed/A.mp3").path))
        do { _ = try await coordinator.projectOutputs(); XCTFail("Do not rewrite moved sidecars until the directory receipt is complete") }
        catch SharedLibraryOperationError.unfinishedOperation {}
        let reopened = SharedLibraryCoordinator(root: root, writerID: coordinator.writerID, witnessDirectory: root.deletingLastPathComponent().appendingPathComponent("local"))
        let complete = try await reopened.resumeFolderOperation(id: id)
        XCTAssertEqual(complete.result, .complete)
        let again = try await reopened.resumeFolderOperation(id: id)
        XCTAssertEqual(again.result, .complete)
    }
    func testUntrackedOwnedSidecarPreventsFolderRenameWithoutMovingAnything() async throws {
        let (root, _, store) = try await fixture()
        let file = root.appendingPathComponent("Folder/A.transcript.json")
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        object["transcriptionModel"] = "external unreviewed edit"
        let bytes = try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
        try bytes.write(to: file)
        do { _ = try await store.renameFolder(from: "Folder", to: "Renamed"); XCTFail("Review changed sidecar first") }
        catch SharedProjectionWriteError.untracked {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Folder/A.mp3").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Renamed").path))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testCancellationAfterFolderIntentAcceptanceStillHasRestartReceipt() async throws {
        let (root, original, _) = try await fixture()
        let folders = try await original.snapshots(kinds: [.folder])
        let id = try XCTUnwrap(folders.first { $0.state.value(for: "name") == .text("Folder") }?.state.id)
        let cancelled = SharedLibraryCoordinator(root: root, writerID: original.writerID,
            witnessDirectory: root.deletingLastPathComponent().appendingPathComponent("local"),
            afterCommit: { withUnsafeCurrentTask { $0?.cancel() } })
        let task = Task { try await cancelled.renameFolder(from: "Folder", to: "Renamed") }
        do { _ = try await task.value; XCTFail("Cancel after accepted logical rename") } catch is CancellationError {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Folder/A.mp3").path))
        let complete = try await original.resumeFolderOperation(id: id)
        XCTAssertEqual(complete.result, .complete)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Renamed/A.mp3").path))
    }

    func testCancellationAfterAcceptedFolderCreationRetainsRestartPlan() async throws {
        let (root, original, _) = try await fixture()
        let cancelled = SharedLibraryCoordinator(root: root, writerID: original.writerID,
            witnessDirectory: root.deletingLastPathComponent().appendingPathComponent("local"),
            afterCommit: { withUnsafeCurrentTask { $0?.cancel() } })
        let task = Task { try await cancelled.createSharedFolder(named: "Created") }
        do { try await task.value; XCTFail("Report cancellation after acceptance") } catch is CancellationError {}
        let views = try await original.snapshots(kinds: [.folder])
        let id = try XCTUnwrap(views.first { $0.state.value(for: "name") == .text("Created") }?.state.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Created").path))
        let reopened = SharedLibraryCoordinator(root: root, writerID: original.writerID,
            witnessDirectory: root.deletingLastPathComponent().appendingPathComponent("local"))
        let resumed = try await reopened.resumeFolderOperation(id: id)
        XCTAssertEqual(resumed.result, .complete)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Created").path))
        let repeated = try await reopened.resumeFolderOperation(id: id)
        XCTAssertEqual(repeated.result, .complete)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Folder/A.mp3")), Data("Folder/A.mp3".utf8))
    }

    func testSharedFolderDeleteDisposesOwnedRecordingsAndOnlyEmptyDirectories() async throws {
        let (root, coordinator, store) = try await fixture()
        try FileManager.default.removeItem(at: root.appendingPathComponent("Folder/.notes"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("Folder/Notes.txt"))
        try await store.deleteFolder(named: "Folder")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Folder").path))
        let views = try await coordinator.snapshots(kinds: [.recording, .folder])
        XCTAssertTrue(views.allSatisfy { $0.state.lifecycle == .deleted })
        let recycled = root.deletingLastPathComponent().appendingPathComponent("recycled")
        XCTAssertEqual(LibraryFileDiscovery.files(in: recycled, suffix: ".mp3").count, 2)
    }
    func testSharedFolderDeletePreservesUnknownAndHiddenFilesAndRemainsPending() async throws {
        let (root, _, store) = try await fixture()
        do { try await store.deleteFolder(named: "Folder"); XCTFail("Keep unknown entries") }
        catch SharedLibraryOperationError.unfinishedOperation {}
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Folder/.notes")), Data("keep hidden notes".utf8))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Folder/Notes.txt")), Data("keep unknown document".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Folder").path))
    }

    func testActiveNestedWorkKeepsAllFolderAudioUntilDeletionResumes() async throws {
        let (root, coordinator, store) = try await fixture()
        try FileManager.default.removeItem(at: root.appendingPathComponent("Folder/.notes"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("Folder/Notes.txt"))
        let reference = try await coordinator.reference(to: "Folder/Nested/B.mp3")
        let token = try await coordinator.pinJob(.init(id: reference.entityID, kind: .recording), audioURL: root.appendingPathComponent("Folder/Nested/B.mp3"))
        do { try await store.deleteFolder(named: "Folder"); XCTFail("Wait for nested work") }
        catch SharedLibraryOperationError.unfinishedOperation {}
        let pending = await store.sharedFolderOperation
        XCTAssertEqual(pending?.result, .waitingForActiveWork)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Folder/A.mp3").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Folder/Nested/B.mp3").path))
        await coordinator.finishJob(token)
        try await store.deleteFolder(named: "Folder")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Folder").path))
    }
    func testNewChildAfterFrozenDeletionRequestRequiresReplanning() async throws {
        let (root, coordinator, store) = try await fixture()
        let reference = try await coordinator.reference(to: "Folder/A.mp3")
        let token = try await coordinator.pinJob(.init(id: reference.entityID, kind: .recording))
        do { try await store.deleteFolder(named: "Folder"); XCTFail() } catch SharedLibraryOperationError.unfinishedOperation {}
        let folders = try await coordinator.snapshots(kinds: [.folder])
        let id = try XCTUnwrap(folders.first { $0.state.value(for: "name") == .text("Folder") }?.state.id)
        let entity = SharedEntityIdentity(id: UUID(), kind: .recording)
        _ = try await coordinator.edit(.init(base: try await coordinator.read(entity), changes: [
            .assign(field: "initialPath", value: .text("Folder/Late.mp3")), .assign(field: "title", value: .text("Late")), .assign(field: "folder", value: .text(id.uuidString))]))
        await coordinator.finishJob(token)
        let result = try await coordinator.resumeFolderDeletion(id: id)
        XCTAssertEqual(result.result, .needsReplanning)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Folder/A.mp3").path))
    }
    func testMetadataOnlyChildAtFinalRemovalCannotLoseItsParent() async throws {
        let (root, coordinator, _) = try await fixture()
        try FileManager.default.removeItem(at: root.appendingPathComponent("Folder/.notes"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("Folder/Notes.txt"))
        let folders = try await coordinator.snapshots(kinds: [.folder])
        let id = try XCTUnwrap(folders.first { $0.state.value(for: "name") == .text("Folder") }?.state.id)
        let result = try await coordinator.deleteFolder(named: "Folder", beforeFinalRemoval: {
            let entity = SharedEntityIdentity(id: UUID(), kind: .recording)
            _ = try await coordinator.edit(.init(base: try await coordinator.read(entity), changes: [
                .assign(field: "initialPath", value: .text("Folder/Late.mp3")), .assign(field: "title", value: .text("Late")), .assign(field: "folder", value: .text(id.uuidString))]))
        })
        XCTAssertEqual(result.result, .needsReplanning)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Folder").path), "Metadata can arrive before audio; preserve the parent")
    }

    private func deliver(_ source: URL, to destination: URL, writer: UUID) throws {
        let tree = source.appendingPathComponent(".docktape").resolvingSymlinksInPath()
        let iterator = try XCTUnwrap(FileManager.default.enumerator(at: tree, includingPropertiesForKeys: nil))
        for case let file as URL in iterator where file.pathExtension == "json" {
            let bytes = try Data(contentsOf: file)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            let payload = object["payload"] as? [String: Any]
            let owner = (object["writerID"] as? String) ?? (payload?["writer"] as? String) ?? (object["founder"] as? String)
            guard owner.flatMap(UUID.init(uuidString:)) == writer else { continue }
            let path = String(file.resolvingSymlinksInPath().path.dropFirst(tree.path.count + 1))
            let target = destination.appendingPathComponent(".docktape/" + path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: target, options: .atomic)
        }
    }
    func testOfflineCohortKeepsFolderAudioUntilEachDeletionIsAcknowledged() async throws {
        let (left, a, store) = try await fixture()
        try FileManager.default.removeItem(at: left.appendingPathComponent("Folder/.notes"))
        try FileManager.default.removeItem(at: left.appendingPathComponent("Folder/Notes.txt"))
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        roots.append(parent)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let right = parent.appendingPathComponent("library")
        try FileManager.default.copyItem(at: left, to: right)
        let b = SharedLibraryCoordinator(root: right, writerID: UUID(), witnessDirectory: parent.appendingPathComponent("local"), trash: { url in
            let recycled = parent.appendingPathComponent("recycled")
            try FileManager.default.createDirectory(at: recycled, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: recycled.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent))
        })
        try await b.requestEnrollment(requestID: UUID(), label: "Fixture B")
        try deliver(right, to: left, writer: b.writerID); try await a.refresh()
        try deliver(left, to: right, writer: a.writerID); try await b.refresh()
        try deliver(right, to: left, writer: b.writerID); try await a.refresh()
        do { try await store.deleteFolder(named: "Folder"); XCTFail("Wait for offline peer") }
        catch SharedLibraryOperationError.unfinishedOperation {}
        let currentOutcome = await store.sharedFolderOperation
        let pending = try XCTUnwrap(currentOutcome)
        XCTAssertEqual(pending.result, .waitingForAcknowledgments)
        XCTAssertTrue(FileManager.default.fileExists(atPath: left.appendingPathComponent("Folder/A.mp3").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: left.appendingPathComponent("Folder/Nested/B.mp3").path))
        var outcome = pending
        for _ in 0..<6 {
            try deliver(left, to: right, writer: a.writerID)
            try Data(contentsOf: left.appendingPathComponent("library.json")).write(to: right.appendingPathComponent("library.json"), options: .atomic)
            try await b.refresh()
            let views = try await b.snapshots(kinds: [.recording, .folder])
            for view in views where view.state.lifecycle == .deleted {
                try await b.acknowledgeOperation(entity: .init(id: view.state.id, kind: view.state.kind), purpose: .delete)
            }
            try deliver(right, to: left, writer: b.writerID)
            outcome = try await a.resumeFolderDeletion(id: pending.id)
            if !FileManager.default.fileExists(atPath: left.appendingPathComponent("Folder/A.mp3").path),
               FileManager.default.fileExists(atPath: right.appendingPathComponent("Folder/A.mp3").path),
               outcome.result != .complete {
                // Apply only A's completed child removal to the disposable
                // replica while the parent request is still pending.
                try deliver(left, to: right, writer: a.writerID)
                try Data(contentsOf: left.appendingPathComponent("library.json")).write(to: right.appendingPathComponent("library.json"), options: .atomic)
                for suffix in [".mp3", ".transcript.json", ".summary.json", ".txt", ".transcript.md", ".summary.md"] {
                    let file = right.appendingPathComponent("Folder/A" + suffix)
                    if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
                }
                let leftover = right.appendingPathComponent("Folder/A.summary.md")
                try Data("provider has not removed this sidecar".utf8).write(to: leftover)
                let incomplete = try await b.resumeFolderDeletion(id: pending.id)
                XCTAssertEqual(incomplete.result, .waitingForFile("Folder/A.mp3"), "A remaining sidecar is not a completed removal")
                XCTAssertEqual(try Data(contentsOf: leftover), Data("provider has not removed this sidecar".utf8))
                try FileManager.default.removeItem(at: leftover)
                let placeholder = right.appendingPathComponent("Folder/.A.mp3.icloud")
                try Data().write(to: placeholder)
                let cold = try await b.resumeFolderDeletion(id: pending.id)
                XCTAssertEqual(cold.result, .waitingForFile("Folder/A.mp3"), "An online-only placeholder is not a completed removal")
                try FileManager.default.removeItem(at: placeholder)
                let continued = try await b.resumeFolderDeletion(id: pending.id)
                XCTAssertNotEqual(continued.result, .waitingForFile("Folder/A.mp3"), "Acknowledged partial removal must not wait for already removed audio")
            }
            if outcome.result == .complete { break }
        }
        XCTAssertEqual(outcome.result, .complete)
        XCTAssertFalse(FileManager.default.fileExists(atPath: left.appendingPathComponent("Folder").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: right.appendingPathComponent("Folder/A.mp3").path), "Synthetic delivery applied only the acknowledged first child")
        // Deliver the provider's completed removal to this disposable replica.
        try deliver(left, to: right, writer: a.writerID)
        try Data(contentsOf: left.appendingPathComponent("library.json")).write(to: right.appendingPathComponent("library.json"), options: .atomic)
        if FileManager.default.fileExists(atPath: right.appendingPathComponent("Folder").path) {
            try FileManager.default.removeItem(at: right.appendingPathComponent("Folder"))
        }
        let mirrored = try await b.resumeFolderDeletion(id: pending.id)
        XCTAssertEqual(mirrored.result, .complete, "A complete acknowledged provider removal does not wait for absent original audio")
    }

    func testCancelledFolderDeletionRequestResumesFromSharedState() async throws {
        let (root, original, _) = try await fixture()
        try FileManager.default.removeItem(at: root.appendingPathComponent("Folder/.notes"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("Folder/Notes.txt"))
        let folders = try await original.snapshots(kinds: [.folder])
        let id = try XCTUnwrap(folders.first { $0.state.value(for: "name") == .text("Folder") }?.state.id)
        let recycled = root.deletingLastPathComponent().appendingPathComponent("recycled")
        let cancelled = SharedLibraryCoordinator(root: root, writerID: original.writerID,
            witnessDirectory: root.deletingLastPathComponent().appendingPathComponent("local"), afterCommit: { withUnsafeCurrentTask { $0?.cancel() } },
            trash: { url in
                try FileManager.default.createDirectory(at: recycled, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: url, to: recycled.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent))
            })
        let task = Task { try await cancelled.deleteFolder(named: "Folder") }
        do { _ = try await task.value; XCTFail("Cancel after requested scope is accepted") } catch is CancellationError {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Folder/A.mp3").path))
        let result = try await original.resumeFolderDeletion(id: id)
        XCTAssertEqual(result.result, .complete)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Folder").path))
    }

}
