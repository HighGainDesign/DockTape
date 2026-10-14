// © 2026 High Gain Design. All rights reserved.
import XCTest
import CryptoKit
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
    func testCancellationAfterAcceptedRelocationRetainsRestartPlan() async throws {
        try await checkCancelledAcceptedRecording(deleting: false)
    }
    func testCancellationAfterAcceptedDeletionRetainsRestartPlan() async throws {
        try await checkCancelledAcceptedRecording(deleting: true)
    }
    func testRefreshBetweenAcceptedDeletionAndCleanupPreservesReplayInputs() async throws {
        try await checkCancelledAcceptedRecording(deleting: true, refreshing: true)
    }
    func testRefreshBetweenAcceptedRelocationAndMoveKeepsProjectionPending() async throws {
        try await checkCancelledAcceptedRecording(deleting: false, refreshing: true)
    }
    private func checkCancelledAcceptedRecording(deleting: Bool, refreshing: Bool = false) async throws {
            let (root, original, _) = try await fixture()
            let ref = try await original.reference(to: "Meeting.mp3")
            let directory = root.deletingLastPathComponent()
            let cancelled = SharedLibraryCoordinator(root: root, writerID: original.writerID,
                witnessDirectory: directory.appendingPathComponent("local"),
                afterCommit: {
                    if refreshing {
                        do {
                            // Match AppState's refresh sequence before projection.
                            let entity = SharedEntityIdentity(id: ref.entityID, kind: .recording)
                            let before = try await original.read(entity)
                            try await original.refresh()
                            let after = try await original.read(entity)
                            XCTAssertEqual(before.state.fields, after.state.fields, "Refresh changes compaction metadata, not the accepted causal fields")
                            _ = try await original.projectOutputs()
                            if !deleting { XCTFail("Do not publish relocated sidecars before the physical move") }
                        } catch SharedLibraryOperationError.unfinishedOperation {
                            if deleting { XCTFail("A deletion refresh may update metadata while retaining replay inputs") }
                        } catch { XCTFail("Unexpected refresh error: \(error)") }
                    }
                    withUnsafeCurrentTask { $0?.cancel() }
                }, trash: { url in
                    let recycled = directory.appendingPathComponent("recycled")
                    try FileManager.default.createDirectory(at: recycled, withIntermediateDirectories: true)
                    try FileManager.default.moveItem(at: url, to: recycled.appendingPathComponent(url.lastPathComponent))
                })
            let task = Task {
                if deleting { _ = try await cancelled.deleteSharedRecording(filename: "Meeting.mp3") }
                else { _ = try await cancelled.relocateRecording(filename: "Meeting.mp3", title: "Renamed") }
            }
            do { try await task.value; XCTFail("Cancellation after acceptance must be reported") }
            catch is CancellationError {}
            let entity = SharedEntityIdentity(id: ref.entityID, kind: .recording)
            let accepted = try await original.read(entity)
            if deleting { XCTAssertEqual(accepted.state.lifecycle, .deleted) }
            else { XCTAssertEqual(accepted.state.value(for: "title"), .text("Renamed")) }
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Meeting.mp3")), Data("single synthetic original".utf8))
            let reopened = SharedLibraryCoordinator(root: root, writerID: original.writerID,
                witnessDirectory: directory.appendingPathComponent("local"), trash: { url in
                    let recycled = directory.appendingPathComponent("recycled")
                    try FileManager.default.createDirectory(at: recycled, withIntermediateDirectories: true)
                    try FileManager.default.moveItem(at: url, to: recycled.appendingPathComponent(url.lastPathComponent))
                })
            let resumed = try await reopened.resumeRecordingOperation(id: ref.entityID)
            XCTAssertEqual(resumed.result, .complete)
            XCTAssertNil(resumed.projectionError)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Meeting.mp3").path))
            if !deleting {
                XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Renamed.mp3")), Data("single synthetic original".utf8))
                let current = try await reopened.resolve(ref)
                XCTAssertEqual(current, "Renamed.mp3")
            }
    }

    private actor Once {
        private var ran = false
        func take() -> Bool { if ran { return false }; ran = true; return true }
    }
    func testOwnedProjectionDuringMovePreparationCannotBreakAcceptedReplay() async throws {
        let (root, coordinator, _) = try await fixture()
        let ref = try await coordinator.reference(to: "Meeting.mp3")
        let once = Once()
        let result = try await coordinator.relocateRecording(filename: "Meeting.mp3", title: "Renamed", beforeCommit: {
            guard await once.take() else { return }
            let entity = SharedEntityIdentity(id: ref.entityID, kind: .recording)
            _ = try await coordinator.edit(.init(base: try await coordinator.read(entity), changes: [.assign(field: "metadata.mode", value: .text("\"Wip\""))]))
            try await coordinator.refresh()
            _ = try await coordinator.projectOutputs()
        })
        XCTAssertEqual(result.result, .complete)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Renamed.mp3")), Data("single synthetic original".utf8))
        let transcript = try SharedContentCoding.decoder().decode(Transcript.self, from: Data(contentsOf: root.appendingPathComponent("Renamed.transcript.json")))
        XCTAssertEqual(transcript.segments.first?.text, "Conversation")
        let view = try await coordinator.read(.init(id: ref.entityID, kind: .recording))
        XCTAssertEqual(view.state.value(for: "metadata.mode"), .text("\"Wip\""))
    }

    func testPreparationRetryCannotOverwriteAnUnseenCompetingName() async throws {
        let (root, coordinator, _) = try await fixture()
        let ref = try await coordinator.reference(to: "Meeting.mp3")
        let entity = SharedEntityIdentity(id: ref.entityID, kind: .recording)
        let once = Once()
        do {
            _ = try await coordinator.relocateRecording(filename: "Meeting.mp3", title: "Renamed", beforeCommit: {
                guard await once.take() else { return }
                _ = try await coordinator.edit(.init(base: try await coordinator.read(entity), changes: [.assign(field: "title", value: .text("Other name"))]))
            })
            XCTFail("Retry cannot replace a competing intent")
        } catch SharedLibraryCoordinatorError.staleReview {}
        let current = try await coordinator.read(entity)
        XCTAssertEqual(current.state.value(for: "title"), .text("Other name"))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Meeting.mp3")), Data("single synthetic original".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Renamed.mp3").path))
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
        for case let file as URL in iterator where file.pathExtension == "json" {
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
        let (root, _, store) = try await fixture(project: false)
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

    func testQueuedReferenceFollowsCompletedRenameAndMoveButNotDeletion() async throws {
        let (_, coordinator, store) = try await fixture()
        let reference = try await coordinator.reference(to: "Meeting.mp3")
        _ = try await store.renameRecording(filename: "Meeting.mp3", to: "Renamed")
        let renamed = try await coordinator.resolve(reference)
        XCTAssertEqual(renamed, "Renamed.mp3")
        try await store.createFolder(named: "Archive")
        _ = try await store.moveRecording(filename: "Renamed.mp3", toFolder: "Archive")
        let moved = try await coordinator.resolve(reference)
        XCTAssertEqual(moved, "Archive/Renamed.mp3")
        _ = try await coordinator.edit(.init(base: try await coordinator.recording(at: moved), changes: [.delete]))
        do { _ = try await coordinator.resolve(reference); XCTFail("Deleted reference must not target physical leftovers") }
        catch SharedLibraryCoordinatorError.staleJob {}
    }
    func testQueuedReferenceDoesNotAdvertiseUnfinishedPhysicalRelocation() async throws {
        enum Stopped: Error { case interrupted }
        let (_, coordinator, _) = try await fixture()
        let reference = try await coordinator.reference(to: "Meeting.mp3")
        do { _ = try await coordinator.relocateRecording(filename: "Meeting.mp3", title: "Renamed", afterMutation: { _ in throw Stopped.interrupted }); XCTFail() }
        catch Stopped.interrupted {}
        do { _ = try await coordinator.resolve(reference); XCTFail("Wait for coherent published location") }
        catch SharedLibraryOperationError.unfinishedOperation {}
    }

    func testReferenceCannotCrossLibraryBindingEvenWithSameLegacyEntityID() async throws {
        let (_, first, _) = try await fixture()
        let (_, second, _) = try await fixture()
        let reference = try await first.reference(to: "Meeting.mp3")
        do { _ = try await second.resolve(reference); XCTFail("Reference is library-bound") }
        catch SharedLibraryCoordinatorError.differentBinding {}
    }

    func testSharedImportPublishesStableIdentityAndSkipsIdenticalBytesAfterRename() async throws {
        let (root, coordinator, store) = try await fixture()
        let data = Data([0xFF, 0xFB, 0x90, 0x64, 1, 2, 3, 4])
        let entry = FileEntry(filename: "New.hda", size: UInt32(data.count))
        let imported = try await store.importRecording(hdaData: data, entry: entry)
        XCTAssertEqual(imported?.filename, "New.mp3")
        XCTAssertNotNil(imported?.reference)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("New.mp3")), data)
        let identity = try await coordinator.reference(to: "New.mp3")
        _ = try await store.renameRecording(filename: "New.mp3", to: "Personal title")
        let duplicate = try await store.importRecording(hdaData: data, entry: entry)
        XCTAssertNil(duplicate)
        let resolved = try await coordinator.resolve(identity)
        XCTAssertEqual(resolved, "Personal title.mp3")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("New.mp3").path))
    }
    func testSharedImportRepairsKnownAudioWithoutDiscardingSidecars() async throws {
        let (root, coordinator, store) = try await fixture()
        let data = Data([0xFF, 0xFB, 0x90, 0x64, 5, 6, 7, 8])
        let entry = FileEntry(filename: "Repair.hda", size: UInt32(data.count))
        _ = try await store.importRecording(hdaData: data, entry: entry)
        let identity = try await coordinator.reference(to: "Repair.mp3")
        let transcript = Transcript(recordingFilename: "Repair.mp3", transcriptionModel: "fixture", hasSpeakerLabels: false,
            segments: [.init(startTime: 0, endTime: 1, text: "Keep this transcript")])
        try await TranscriptStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: coordinator)).save(transcript, mp3Filename: "Repair.mp3")
        _ = try await coordinator.projectOutputs()
        try Data("corrupted".utf8).write(to: root.appendingPathComponent("Repair.mp3"))
        _ = try await store.importRecording(hdaData: data, entry: entry)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Repair.mp3")), data)
        let saved = await TranscriptStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: coordinator)).transcript(for: "Repair.mp3")
        XCTAssertEqual(saved?.segments.first?.text, "Keep this transcript")
        let repairedReference = try await coordinator.reference(to: "Repair.mp3")
        XCTAssertEqual(repairedReference, identity)
        XCTAssertTrue(LibraryFileDiscovery.files(in: root, suffix: ".mp3").allSatisfy { !$0.relativePath.contains("backup") })
    }

    func testSharedRepairWorksWithOfflinePeerButChangedAudioWaitsAndResumes() async throws {
        let (left, a, store) = try await fixture()
        let original = Data([0xFF, 0xFB, 0x90, 0x64, 1, 2, 3, 4])
        let entry = FileEntry(filename: "Offline.hda", size: UInt32(original.count))
        _ = try await store.importRecording(hdaData: original, entry: entry)
        let entity = SharedEntityIdentity(id: try await a.reference(to: "Offline.mp3").entityID, kind: .recording)
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        roots.append(parent)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let right = parent.appendingPathComponent("library")
        try FileManager.default.copyItem(at: left, to: right)
        let b = SharedLibraryCoordinator(root: right, writerID: UUID(), witnessDirectory: parent.appendingPathComponent("local"))
        try await b.requestEnrollment(requestID: UUID(), label: "Fixture B")
        try deliverOwner(right, to: left, writer: b.writerID); try await a.refresh()
        try deliverOwner(left, to: right, writer: a.writerID); try await b.refresh()
        try deliverOwner(right, to: left, writer: b.writerID); try await a.refresh()
        try Data("corrupt".utf8).write(to: left.appendingPathComponent("Offline.mp3"))
        _ = try await store.importRecording(hdaData: original, entry: entry)
        XCTAssertEqual(try Data(contentsOf: left.appendingPathComponent("Offline.mp3")), original)
        let changed = Data([0xFF, 0xFB, 0x90, 0x64, 9, 9, 9, 9])
        do { _ = try await store.importRecording(hdaData: changed, entry: entry); XCTFail("Changed content waits for offline peer") }
        catch SharedLibraryOperationError.unfinishedOperation {}
        XCTAssertEqual(try Data(contentsOf: left.appendingPathComponent("Offline.mp3")), original)
        let pending = await store.sharedOperation
        XCTAssertEqual(pending?.result, .waitingForAcknowledgments)
        do { _ = try await a.projectOutputs(); XCTFail("Do not publish pending audio checksum") }
        catch SharedLibraryOperationError.unfinishedOperation {}
        let reopened = SharedLibraryCoordinator(root: left, writerID: a.writerID, witnessDirectory: left.deletingLastPathComponent().appendingPathComponent("local"))
        let waiting = try await reopened.resumeRecordingOperation(id: entity.id)
        XCTAssertEqual(waiting.result, .waitingForAcknowledgments)
        try deliverOwner(left, to: right, writer: a.writerID)
        try Data(contentsOf: left.appendingPathComponent("library.json")).write(to: right.appendingPathComponent("library.json"), options: .atomic)
        try await b.refresh()
        try await b.acknowledgeOperation(entity: entity, purpose: .replaceAudio)
        try deliverOwner(right, to: left, writer: b.writerID)
        let complete = try await reopened.resumeRecordingOperation(id: entity.id)
        XCTAssertEqual(complete.result, .complete)
        XCTAssertNil(complete.projectionError)
        XCTAssertEqual(try Data(contentsOf: left.appendingPathComponent("Offline.mp3")), changed)
        let repeated = try await reopened.resumeRecordingOperation(id: entity.id)
        XCTAssertEqual(repeated.result, .complete)
        XCTAssertTrue(LibraryFileDiscovery.files(in: left.appendingPathComponent(".docktape/staging"), suffix: ".mp3").isEmpty)
    }

    func testImportCancelledAfterSemanticAcceptanceCanResumeWithSameIdentity() async throws {
        let (root, coordinator, _) = try await fixture()
        let interrupted = SharedLibraryCoordinator(root: root, writerID: coordinator.writerID,
            witnessDirectory: root.deletingLastPathComponent().appendingPathComponent("local"),
            afterCommit: { withUnsafeCurrentTask { $0?.cancel() } })
        let store = RecordingStore(baseDirectory: root, shared: SharedRecordingMetadataAdapter(coordinator: interrupted))
        try await store.setup()
        let bytes = Data([0xFF, 0xFB, 0x90, 0x64, 1, 2, 3, 4])
        let entry = FileEntry(filename: "Interrupted.hda", size: UInt32(bytes.count))
        let task = Task { try await store.importRecording(hdaData: bytes, entry: entry) }
        do { _ = try await task.value; XCTFail("Cancel after accepted intent") } catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Interrupted.mp3").path))
        let before = try await coordinator.recording(at: "Interrupted.mp3")
        let resumed = RecordingStore(baseDirectory: root, shared: SharedRecordingMetadataAdapter(coordinator: coordinator))
        try await resumed.setup()
        let imported = try await resumed.importRecording(hdaData: bytes, entry: entry)
        XCTAssertEqual(imported?.reference?.entityID, before.state.id)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Interrupted.mp3")), bytes)
    }
    func testVerifiedSourceImportIdentityIsDeterministicAndChecksumSkipDetectsCorruption() async throws {
        let (root, coordinator, store) = try await fixture()
        let bytes = Data([0xFF, 0xFB, 0x90, 0x64, 1, 2, 3, 4])
        let md5 = Insecure.MD5.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let entry = FileEntry(filename: "Verified.hda", size: UInt32(bytes.count), md5: md5)
        let imported = try await store.importRecording(hdaData: bytes, entry: entry)
        XCTAssertEqual(imported?.reference?.entityID, try SharedLibraryIdentity.deviceImport(filename: entry.filename, sourceMD5: md5))
        _ = try await store.renameRecording(filename: "Verified.mp3", to: "Verified title")
        let verified = try await store.matchesVerifiedImport(entry)
        XCTAssertTrue(verified)
        try Data("corrupt".utf8).write(to: root.appendingPathComponent("Verified title.mp3"))
        let corrupted = try await store.matchesVerifiedImport(entry)
        XCTAssertFalse(corrupted)
        let other = RecordingStore(baseDirectory: root, shared: SharedRecordingMetadataAdapter(coordinator: coordinator))
        try await other.setup()
        _ = try await other.importRecording(hdaData: bytes, entry: entry)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Verified title.mp3")), bytes)
    }

    func testImportInterruptedAfterStagingReusesInputWithoutAccumulatingFiles() async throws {
        enum Interrupted: Error { case afterStaging }
        let (root, coordinator, store) = try await fixture()
        let bytes = Data([0xFF, 0xFB, 0x90, 0x64, 1, 2, 3, 4])
        let entry = FileEntry(filename: "Staged.hda", size: UInt32(bytes.count))
        let md5 = Insecure.MD5.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        do { _ = try await coordinator.importAudio(bytes, entry: entry, rawMD5: md5, beforeReplay: { throw Interrupted.afterStaging }); XCTFail() }
        catch Interrupted.afterStaging {}
        let staged = root.appendingPathComponent(".docktape/staging")
        XCTAssertEqual(LibraryFileDiscovery.files(in: staged, suffix: ".mp3").count, 1)
        _ = try await store.importRecording(hdaData: bytes, entry: entry)
        XCTAssertTrue(LibraryFileDiscovery.files(in: staged, suffix: ".mp3").isEmpty, "Retry consumes its existing staged input")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Staged.mp3")), bytes)
    }

    func testTwoOfflineImportsOfVerifiedSourceConvergeOnOneEntity() async throws {
        let (left, a, first) = try await fixture()
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        roots.append(parent)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let right = parent.appendingPathComponent("library")
        try FileManager.default.copyItem(at: left, to: right)
        let b = SharedLibraryCoordinator(root: right, writerID: UUID(), witnessDirectory: parent.appendingPathComponent("local"))
        try await b.requestEnrollment(requestID: UUID(), label: "Fixture B")
        try deliverOwner(right, to: left, writer: b.writerID); try await a.refresh()
        try deliverOwner(left, to: right, writer: a.writerID); try await b.refresh()
        try deliverOwner(right, to: left, writer: b.writerID); try await a.refresh()
        let second = RecordingStore(baseDirectory: right, shared: SharedRecordingMetadataAdapter(coordinator: b))
        try await second.setup()
        let bytes = Data([0xFF, 0xFB, 0x90, 0x64, 1, 2, 3, 4])
        let md5 = Insecure.MD5.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let entry = FileEntry(filename: "Shared source.hda", size: UInt32(bytes.count), md5: md5)
        let one = try await first.importRecording(hdaData: bytes, entry: entry)
        let two = try await second.importRecording(hdaData: bytes, entry: entry)
        XCTAssertEqual(one?.reference, two?.reference)
        let entity = SharedEntityIdentity(id: try XCTUnwrap(one?.reference?.entityID), kind: .recording)
        try deliverOwner(left, to: right, writer: a.writerID)
        try deliverOwner(right, to: left, writer: b.writerID)
        try await a.refresh(); try await b.refresh()
        let mergedA = try await a.read(entity), mergedB = try await b.read(entity)
        XCTAssertTrue(mergedA.state.conflicts.isEmpty)
        XCTAssertTrue(mergedB.state.conflicts.isEmpty)
        XCTAssertEqual(mergedA.state, mergedB.state)
        _ = try await a.projectOutputs(); _ = try await b.projectOutputs()
        XCTAssertEqual(LibraryFileDiscovery.files(in: left, suffix: ".mp3").filter { $0.relativePath == "Shared source.mp3" }.count, 1)
        XCTAssertEqual(LibraryFileDiscovery.files(in: right, suffix: ".mp3").filter { $0.relativePath == "Shared source.mp3" }.count, 1)
    }

    func testReusedLegacyPathResolvesNewOwnerInsteadOfOldBootstrapIdentity() async throws {
        let (_, coordinator, store) = try await fixture()
        let original = try await coordinator.reference(to: "Meeting.mp3")
        _ = try await store.renameRecording(filename: "Meeting.mp3", to: "Original meeting")
        let bytes = Data([0xFF, 0xFB, 0x90, 0x64, 1, 2, 3, 4])
        let imported = try await store.importRecording(hdaData: bytes, entry: FileEntry(filename: "Replacement.hda", size: UInt32(bytes.count)))
        let replacement = try XCTUnwrap(imported?.reference)
        _ = try await store.renameRecording(filename: "Replacement.mp3", to: "Meeting")
        let actual = try await coordinator.reference(to: "Meeting.mp3")
        XCTAssertEqual(actual, replacement)
        XCTAssertNotEqual(actual, original)
        let originalPath = try await coordinator.resolve(original)
        XCTAssertEqual(originalPath, "Original meeting.mp3")
    }

    private actor ReadGate {
        var armed = false, waiting = false
        private var continuation: CheckedContinuation<Void, Never>?
        func arm() { armed = true }
        func wait() async {
            guard armed else { return }
            waiting = true
            await withCheckedContinuation { continuation = $0 }
        }
        func release() { armed = false; continuation?.resume(); continuation = nil }
    }
    private func waitFor(_ gate: ReadGate) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await gate.waiting) {
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    func testCatalogStartedDuringRenameCannotEraseAcceptedRecordingReference() async throws {
        let (root, coordinator, _) = try await fixture()
        let operation = ReadGate(), catalog = ReadGate()
        let store = RecordingStore(baseDirectory: root,
            shared: SharedRecordingMetadataAdapter(coordinator: coordinator, beforeLoadReturn: { await catalog.wait() }),
            beforeSharedFileOperation: { await operation.wait() })
        try await store.setup()
        let reference = try await coordinator.reference(to: "Meeting.mp3")
        await operation.arm()
        let rename = Task { try await store.renameRecording(filename: "Meeting.mp3", to: "Renamed") }
        try await waitFor(operation)
        await catalog.arm()
        let read = Task { try await store.loadLibraryMeta() }
        try await waitFor(catalog)
        await operation.release()
        _ = try await rename.value
        await catalog.release()
        try await read.value
        let result = await store.allRecordings()
        XCTAssertEqual(result.first?.filename, "Renamed.mp3")
        XCTAssertEqual(result.first?.reference, reference)
        XCTAssertEqual(result.first?.mode, "Mee")
    }
    func testCatalogStartedDuringDeleteCannotRestoreRemovedSourceAssociation() async throws {
        let (root, coordinator, _) = try await fixture()
        let operation = ReadGate(), catalog = ReadGate()
        let store = RecordingStore(baseDirectory: root,
            shared: SharedRecordingMetadataAdapter(coordinator: coordinator, beforeLoadReturn: { await catalog.wait() }),
            beforeSharedFileOperation: { await operation.wait() })
        try await store.setup()
        await operation.arm()
        let deletion = Task { try await store.deleteRecordingAndSidecars(filename: "Meeting.mp3") }
        try await waitFor(operation)
        await catalog.arm()
        let read = Task { try await store.loadLibraryMeta() }
        try await waitFor(catalog)
        await operation.release()
        try await deletion.value
        await catalog.release()
        try await read.value
        let imported = await store.allImportedDeviceFilenames()
        XCTAssertTrue(imported.isEmpty, "Late pre-deletion catalog must not restore imported status")
        let mode = await store.mode(for: "Meeting.mp3")
        XCTAssertNil(mode, "Late catalog must not restore deleted metadata")
    }

    func testCapturedMergeReferencesAreRejectedByLegacyStore() async throws {
        let (_, coordinator, _) = try await fixture()
        let reference = try await coordinator.reference(to: "Meeting.mp3")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        roots.append(root)
        let store = RecordingStore(baseDirectory: root)
        try await store.setup()
        var frame = Data(repeating: 0, count: 417)
        frame.replaceSubrange(0..<4, with: [0xFF, 0xFB, 0x90, 0x64])
        for name in ["Left", "Right"] { try frame.write(to: root.appendingPathComponent(name + ".mp3")) }
        do {
            _ = try await store.mergeRecordings(filenames: ["Left.mp3", "Right.mp3"], as: "Wrong library",
                references: ["Left.mp3": reference, "Right.mp3": reference])
            XCTFail("Do not consume shared selections against another legacy binding")
        } catch SharedLibraryCoordinatorError.differentBinding {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Wrong library.mp3").path))
    }

}
