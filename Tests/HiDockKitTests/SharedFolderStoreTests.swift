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
        let coordinator = SharedLibraryCoordinator(root: root, writerID: UUID(), witnessDirectory: parent.appendingPathComponent("local"))
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

}
