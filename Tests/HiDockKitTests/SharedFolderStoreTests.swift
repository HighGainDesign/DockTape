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
        let b = SharedLibraryCoordinator(root: right, writerID: UUID(), witnessDirectory: parent.appendingPathComponent("local"))
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
            if outcome.result == .complete { break }
        }
        XCTAssertEqual(outcome.result, .complete)
        XCTAssertFalse(FileManager.default.fileExists(atPath: left.appendingPathComponent("Folder").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: right.appendingPathComponent("Folder/A.mp3").path), "Synthetic delivery has not applied physical provider removal")
        // Deliver the provider's completed removal to this disposable replica.
        try deliver(left, to: right, writer: a.writerID)
        try Data(contentsOf: left.appendingPathComponent("library.json")).write(to: right.appendingPathComponent("library.json"), options: .atomic)
        try FileManager.default.removeItem(at: right.appendingPathComponent("Folder"))
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
