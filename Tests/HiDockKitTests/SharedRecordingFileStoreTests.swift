// © 2026 High Gain Design. All rights reserved.
import XCTest
@testable import HiDockKit

final class SharedRecordingFileStoreTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() { for root in roots { try? FileManager.default.removeItem(at: root) } }
    private func fixture(project: Bool = true) async throws -> (URL, SharedLibraryCoordinator, RecordingStore) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        roots.append(directory)
        let root = directory.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("single synthetic original".utf8).write(to: root.appendingPathComponent("Meeting.mp3"))
        let legacy = RecordingStore(baseDirectory: root)
        try await legacy.setup()
        try await legacy.setMeta(mode: "Mee", deviceFilename: "device.hda", for: "Meeting.mp3")
        let transcript = Transcript(recordingFilename: "Meeting.mp3", transcriptionModel: "fixture", hasSpeakerLabels: false,
            segments: [.init(startTime: 0, endTime: 1, text: "Conversation")])
        try await TranscriptStore(baseDirectory: root).save(transcript, mp3Filename: "Meeting.mp3")
        let summary = Summary(recordingFilename: "Meeting.mp3", model: "fixture", provider: "fixture", templateUsed: "meeting",
            sections: [.init(heading: "Tasks", content: "Synthetic summary")])
        try await SummaryStore(baseDirectory: root).save(summary, mp3Filename: "Meeting.mp3")
        let coordinator = SharedLibraryCoordinator(root: root, writerID: UUID(), witnessDirectory: directory.appendingPathComponent("local"), trash: { url in
            let recycled = directory.appendingPathComponent("recycled")
            try FileManager.default.createDirectory(at: recycled, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: recycled.appendingPathComponent(url.lastPathComponent))
        })
        _ = try await coordinator.enable()
        if project { _ = try await coordinator.projectOutputs() }
        let store = RecordingStore(baseDirectory: root, shared: SharedRecordingMetadataAdapter(coordinator: coordinator))
        try await store.setup()
        return (root, coordinator, store)
    }
    func testActualStoreRenamePreservesIdentityAudioAssociationAndAllCompanions() async throws {
        let (root, coordinator, store) = try await fixture()
        let before = try await coordinator.recording(at: "Meeting.mp3")
        let renamed = try await store.renameRecording(filename: "Meeting.mp3", to: "Renamed")
        XCTAssertEqual(renamed, "Renamed.mp3")
        let outcome = await store.sharedOperation
        XCTAssertNil(outcome?.projectionError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Meeting.mp3").path))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(renamed)), Data("single synthetic original".utf8))
        for suffix in [".transcript.json", ".summary.json", ".transcript.md", ".summary.md", ".txt"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Meeting" + suffix).path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Renamed" + suffix).path))
        }
        let after = try await coordinator.recording(at: renamed)
        XCTAssertEqual(after.state.id, before.state.id)
        let mode = await store.mode(for: renamed)
        let devices = await store.allImportedDeviceFilenames()
        XCTAssertEqual(mode, "Mee"); XCTAssertEqual(devices, ["device.hda"])
        let transcript = try SharedContentCoding.decoder().decode(Transcript.self,
            from: Data(contentsOf: root.appendingPathComponent("Renamed.transcript.json")))
        XCTAssertEqual(transcript.recordingFilename, renamed)
    }
    func testActualStoreMoveUsesFolderIdentityAndKeepsOneOriginal() async throws {
        let (root, coordinator, store) = try await fixture()
        try await store.createFolder(named: "Archive")
        let before = try await coordinator.recording(at: "Meeting.mp3")
        let moved = try await store.moveRecording(filename: "Meeting.mp3", toFolder: "Archive")
        XCTAssertEqual(moved, "Archive/Meeting.mp3")
        let after = try await coordinator.recording(at: moved)
        XCTAssertEqual(before.state.id, after.state.id)
        let mp3s = LibraryFileDiscovery.files(in: root, suffix: ".mp3")
        XCTAssertEqual(mp3s.map(\.relativePath), [moved])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Archive/Meeting.transcript.md").path))
    }
    func testConflictingDestinationNeverMovesTheOriginal() async throws {
        let (root, coordinator, store) = try await fixture()
        try Data("unrecognized existing audio".utf8).write(to: root.appendingPathComponent("Existing.mp3"))
        let before = try await coordinator.recording(at: "Meeting.mp3")
        do { _ = try await store.renameRecording(filename: "Meeting.mp3", to: "Existing"); XCTFail("Do not replace an unowned path") } catch {}
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Existing.mp3")), Data("unrecognized existing audio".utf8))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Meeting.mp3")), Data("single synthetic original".utf8))
        let current = try await coordinator.read(.init(id: before.state.id, kind: .recording))
        XCTAssertEqual(current.state.value(for: "title"), .text("Meeting"))
    }
    func testRestartResumesPhysicalMoveWithoutDuplicatingAudioOrLosingCompanions() async throws {
        enum Stopped: Error { case afterAudio }
        let (root, coordinator, _) = try await fixture()
        let before = try await coordinator.recording(at: "Meeting.mp3")
        do {
            _ = try await coordinator.relocateRecording(filename: "Meeting.mp3", title: "Renamed", afterMutation: { index in
                if index == 0 { throw Stopped.afterAudio }
            })
            XCTFail("Interrupt after first physical phase")
        } catch Stopped.afterAudio {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Renamed.mp3").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Meeting.transcript.json").path))
        do { _ = try await coordinator.projectOutputs(); XCTFail("Do not advertise an unfinished move") }
        catch SharedLibraryOperationError.unfinishedOperation {}
        let reopened = SharedLibraryCoordinator(root: root, writerID: coordinator.writerID,
            witnessDirectory: root.deletingLastPathComponent().appendingPathComponent("local"))
        let result = try await reopened.resumeRecordingOperation(id: before.state.id)
        XCTAssertEqual(result.result, .complete)
        XCTAssertNil(result.projectionError)
        XCTAssertEqual(result.filename, "Renamed.mp3")
        XCTAssertEqual(LibraryFileDiscovery.files(in: root, suffix: ".mp3").map(\.relativePath), ["Renamed.mp3"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Meeting.transcript.json").path))
        let transcript = try SharedContentCoding.decoder().decode(Transcript.self,
            from: Data(contentsOf: root.appendingPathComponent("Renamed.transcript.json")))
        XCTAssertEqual(transcript.recordingFilename, "Renamed.mp3")
    }
    func testUntrackedCompanionEditPreventsRenameBeforeAudioMoves() async throws {
        let (root, coordinator, store) = try await fixture()
        let url = root.appendingPathComponent("Meeting.transcript.json")
        var raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        raw["transcriptionModel"] = "external edit"
        let external = try JSONSerialization.data(withJSONObject: raw, options: .sortedKeys)
        try external.write(to: url)
        do { _ = try await store.renameRecording(filename: "Meeting.mp3", to: "Renamed"); XCTFail("Preserve untracked content for review") }
        catch SharedProjectionWriteError.untracked(let path) { XCTAssertEqual(path, "Meeting.transcript.json") }
        XCTAssertEqual(try Data(contentsOf: url), external)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Meeting.mp3").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Renamed.mp3").path))
        let current = try await coordinator.recording(at: "Meeting.mp3")
        XCTAssertEqual(current.state.value(for: "title"), .text("Meeting"))
    }

    func testActualStoreDeleteUsesAcceptedLifecycleAndDisposesEveryCompanion() async throws {
        let (root, coordinator, store) = try await fixture()
        let before = try await coordinator.recording(at: "Meeting.mp3")
        try await store.deleteRecordingAndSidecars(filename: "Meeting.mp3")
        let outcome = await store.sharedOperation
        XCTAssertEqual(outcome?.result, .complete)
        XCTAssertNil(outcome?.projectionError)
        let deleted = try await coordinator.read(.init(id: before.state.id, kind: .recording))
        XCTAssertEqual(deleted.state.lifecycle, .deleted)
        for suffix in [".mp3", ".transcript.json", ".summary.json", ".transcript.md", ".summary.md", ".txt"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Meeting" + suffix).path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent("recycled/Meeting" + suffix).path))
        }
    }
    func testActiveJobDelaysDeleteAndItsSavedPlanResumesAfterJobFinishes() async throws {
        let (root, coordinator, _) = try await fixture()
        let before = try await coordinator.recording(at: "Meeting.mp3")
        let entity = SharedEntityIdentity(id: before.state.id, kind: .recording)
        let job = try await coordinator.pinJob(entity)
        let pending = try await coordinator.deleteSharedRecording(filename: "Meeting.mp3")
        XCTAssertEqual(pending.result, .waitingForAcknowledgments)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Meeting.mp3").path))
        await coordinator.finishJob(job)
        try await coordinator.acknowledgeOperation(entity: entity, purpose: .delete)
        let resumed = try await coordinator.resumeRecordingOperation(id: entity.id)
        XCTAssertEqual(resumed.result, .complete)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Meeting.mp3").path))
    }

    private func deliverOwner(_ source: URL, to destination: URL, writer: UUID) throws {
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
    func testOfflineParticipantMustAcknowledgeExactDeleteBeforePhysicalRemoval() async throws {
        let (left, a, _) = try await fixture()
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        roots.append(parent)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let right = parent.appendingPathComponent("library")
        try FileManager.default.copyItem(at: left, to: right)
        let b = SharedLibraryCoordinator(root: right, writerID: UUID(), witnessDirectory: parent.appendingPathComponent("local"))
        try await b.requestEnrollment(requestID: UUID(), label: "Fixture B")
        try deliverOwner(right, to: left, writer: b.writerID)
        try await a.refresh()
        try deliverOwner(left, to: right, writer: a.writerID)
        try await b.refresh()
        try deliverOwner(right, to: left, writer: b.writerID)
        try await a.refresh()
        let entity = SharedEntityIdentity(id: try await a.recording(at: "Meeting.mp3").state.id, kind: .recording)
        let pending = try await a.deleteSharedRecording(filename: "Meeting.mp3")
        XCTAssertEqual(pending.result, .waitingForAcknowledgments)
        XCTAssertTrue(FileManager.default.fileExists(atPath: left.appendingPathComponent("Meeting.mp3").path))
        let stillWaiting = try await a.resumeRecordingOperation(id: entity.id)
        XCTAssertEqual(stillWaiting.result, .waitingForAcknowledgments)
        try deliverOwner(left, to: right, writer: a.writerID)
        try await b.refresh()
        try await b.acknowledgeOperation(entity: entity, purpose: .delete)
        try deliverOwner(right, to: left, writer: b.writerID)
        let finished = try await a.resumeRecordingOperation(id: entity.id)
        XCTAssertEqual(finished.result, .complete)
        XCTAssertFalse(FileManager.default.fileExists(atPath: left.appendingPathComponent("Meeting.mp3").path))
        // This simulated provider has not delivered physical removal yet.
        XCTAssertTrue(FileManager.default.fileExists(atPath: right.appendingPathComponent("Meeting.mp3").path))
    }

    func testResumingCompletedRenameIsIdempotentAfterNewProjectionReleasedOldPath() async throws {
        let (_, coordinator, store) = try await fixture()
        let id = try await coordinator.recording(at: "Meeting.mp3").state.id
        _ = try await store.renameRecording(filename: "Meeting.mp3", to: "Renamed")
        let result = try await coordinator.resumeRecordingOperation(id: id)
        XCTAssertEqual(result.result, .complete)
        XCTAssertEqual(result.filename, "Renamed.mp3")
        XCTAssertNil(result.projectionError)
    }
    func testAnotherRenameCannotSupersedeUnfinishedPlanBeforeReview() async throws {
        enum Stopped: Error { case interrupted }
        let (root, coordinator, store) = try await fixture()
        do {
            _ = try await coordinator.relocateRecording(filename: "Meeting.mp3", title: "Renamed", afterMutation: { _ in throw Stopped.interrupted })
            XCTFail()
        } catch Stopped.interrupted {}
        do { _ = try await store.renameRecording(filename: "Renamed.mp3", to: "Again"); XCTFail("Keep unfinished intent recoverable") }
        catch SharedLibraryOperationError.unfinishedOperation {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Renamed.mp3").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Again.mp3").path))
        let current = try await coordinator.recording(at: "Renamed.mp3")
        XCTAssertEqual(current.state.value(for: "title"), .text("Renamed"))
    }
    func testBootstrapLocationsRemainOwnedThroughMoveBeforeFirstProjection() async throws {
        let (root, coordinator, store) = try await fixture(project: false)
        let renamed = try await store.renameRecording(filename: "Meeting.mp3", to: "Renamed")
        XCTAssertEqual(renamed, "Renamed.mp3")
        let outcome = await store.sharedOperation
        XCTAssertNil(outcome?.projectionError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Meeting.transcript.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Renamed.summary.json").path))
    }

    func testRepeatedRenamesKeepPublicationRegistryBoundedToCurrentPaths() async throws {
        let (root, coordinator, store) = try await fixture()
        var filename = "Meeting.mp3"
        for name in ["First", "Second", "Third"] {
            filename = try await store.renameRecording(filename: filename, to: name)
        }
        let registry = try JSONDecoder().decode(SharedProjectionRegistry.self,
            from: Data(contentsOf: root.appendingPathComponent(".docktape/projections/" + coordinator.writerID.uuidString.lowercased() + ".json")))
        XCTAssertEqual(Set(registry.files.keys), ["library.json", ".templates.json", "Third.transcript.json", "Third.summary.json"])
        XCTAssertEqual(LibraryFileDiscovery.files(in: root, suffix: ".mp3").map(\.relativePath), ["Third.mp3"])
    }

}
