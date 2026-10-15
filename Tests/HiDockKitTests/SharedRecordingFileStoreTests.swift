// © 2026 High Gain Design. All rights reserved.
import XCTest
import CryptoKit
@testable import HiDockKit

final class SharedRecordingFileStoreTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() { for root in roots { try? FileManager.default.removeItem(at: root) } }
    private func fixture(project: Bool = true, directory suppliedDirectory: URL? = nil) async throws -> (URL, SharedLibraryCoordinator, RecordingStore) {
        let directory = suppliedDirectory ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
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
    func testStoreRelocationKeepsSourceAndDestinationReferencesAcrossAwait() async throws {
        for scenario in ["source-move", "source-rename", "destination"] {
            let (root, a, _) = try await fixture()
            try await a.createSharedFolder(named: "Folder")
            let store = RecordingStore(baseDirectory: root, shared: SharedRecordingMetadataAdapter(coordinator: a), beforeSharedFileOperation: {
                if scenario == "destination" {
                    _ = try? await a.renameFolder(from: "Folder", to: "Moved Folder")
                    try? await a.createSharedFolder(named: "Folder")
                } else {
                    _ = try? await a.relocateRecording(filename: "Meeting.mp3", title: "Moved Original")
                    try? Data("replacement audio".utf8).write(to: root.appendingPathComponent("Meeting.mp3"))
                    let entity = SharedEntityIdentity(id: UUID(), kind: .recording)
                    if let base = try? await a.read(entity) {
                        _ = try? await a.edit(.init(base: base, changes: [.assign(field: "initialPath", value: .text("Meeting.mp3")),
                            .assign(field: "title", value: .text("Meeting")), .assign(field: "folder", value: .unset)]))
                    }
                    _ = try? await a.projectOutputs()
                }
            })
            try await store.setup()
            let recording = try await a.reference(to: "Meeting.mp3")
            let folders = await store.folderCatalog(), destination = try XCTUnwrap(folders.references["Folder"])
            do {
                if scenario == "source-rename" { _ = try await store.renameRecording(filename: "Meeting.mp3", to: "Unexpected", reference: recording) }
                else { _ = try await store.moveRecording(filename: "Meeting.mp3", toFolder: "Folder", reference: recording, destinationReference: destination) }
                XCTFail("Awaited operation cannot renew source/destination authority")
            } catch SharedLibraryCoordinatorError.differentBinding {}
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Meeting.mp3").path))
            if scenario != "destination" { XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Moved Original.mp3")), Data("single synthetic original".utf8)) }
        }
    }

    func testLegacyRelocationRefusesTraversalAndSymlinkEscapes() async throws {
        for action in ["move", "rename"] {
            for attack in ["traversal", "symlink", "destination"] where action == "move" || attack != "destination" {
                let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                roots.append(parent)
                let root = parent.appendingPathComponent("library"), outside = parent.appendingPathComponent("outside")
                try FileManager.default.createDirectory(at: root.appendingPathComponent("Folder"), withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
                let original = Data("outside relocation fixture".utf8)
                let source: URL, filename: String, destination: String
                if attack == "traversal" { source = parent.appendingPathComponent("Outside.mp3"); filename = "../Outside.mp3"; destination = "Folder" }
                else if attack == "symlink" {
                    source = outside.appendingPathComponent("Outside.mp3"); filename = "Alias/Outside.mp3"; destination = "Folder"
                    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Alias"), withDestinationURL: outside)
                } else { source = root.appendingPathComponent("Meeting.mp3"); filename = "Meeting.mp3"; destination = "../outside" }
                try original.write(to: source)
                let store = RecordingStore(baseDirectory: root)
                try await store.setup()
                do {
                    if action == "move" { _ = try await store.moveRecording(filename: filename, toFolder: destination) }
                    else { _ = try await store.renameRecording(filename: filename, to: "Unexpected") }
                    XCTFail("A recording action cannot escape its library")
                } catch {}
                XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "Original remains within its original scope")
                if FileManager.default.fileExists(atPath: source.path) { XCTAssertEqual(try Data(contentsOf: source), original) }
            }
        }
    }

    private actor RelocationProbe {
        private(set) var called = false
        func enter() { called = true }
    }
    func testRelocationRefusesSourceAncestorChangeBeforeCommit() async throws {
        for action in ["rename", "root", "other"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let root = directory.appendingPathComponent("library")
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Source"), withIntermediateDirectories: true)
            try Data("source ancestor fixture".utf8).write(to: root.appendingPathComponent("Source/Clip.mp3"))
            let (_, a, _) = try await fixture(directory: directory)
            try await a.createSharedFolder(named: "Other")
            let before = try await a.recording(at: "Source/Clip.mp3"), probe = RelocationProbe()
            let interrupted = SharedLibraryCoordinator(root: root, writerID: a.writerID, witnessDirectory: directory.appendingPathComponent("local"),
                afterCommit: { withUnsafeCurrentTask { $0?.cancel() } })
            do {
                _ = try await a.relocateRecording(filename: "Source/Clip.mp3", title: action == "rename" ? "Unexpected" : nil,
                    toFolder: action == "other" ? "Other" : nil, changeFolder: action != "rename", beforeCommit: {
                        await probe.enter()
                        let changing = Task { try await interrupted.renameFolder(from: "Source", to: "Moved") }
                        do { _ = try await changing.value; XCTFail("Expected interruption after ancestor acceptance") }
                        catch is CancellationError {}
                    })
                XCTFail("Old source paths cannot be accepted after their ancestor changes")
            } catch {}
            let entered = await probe.called
            XCTAssertTrue(entered, "Race must reach the real commit boundary")
            let current = try await a.read(.init(id: before.state.id, kind: .recording))
            XCTAssertEqual(current.state.fields["title"], before.state.fields["title"], "Stale rename was not accepted")
            XCTAssertEqual(current.state.fields["folder"], before.state.fields["folder"], "Stale move was not accepted")
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Source/Clip.mp3")), Data("source ancestor fixture".utf8))
        }
    }

    func testRelocationBindsNestedDestinationAncestors() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), probe = RelocationProbe()
        let root = directory.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Parent/Nested"), withIntermediateDirectories: true)
        let (_, a, _) = try await fixture(directory: directory)
        let before = try await a.recording(at: "Meeting.mp3")
        let interrupted = SharedLibraryCoordinator(root: root, writerID: a.writerID, witnessDirectory: directory.appendingPathComponent("local"),
            afterCommit: { withUnsafeCurrentTask { $0?.cancel() } })
        do {
            _ = try await a.relocateRecording(filename: "Meeting.mp3", toFolder: "Parent/Nested", changeFolder: true, beforeCommit: {
                await probe.enter()
                let changing = Task { try await interrupted.renameFolder(from: "Parent", to: "Moved Parent") }
                do { _ = try await changing.value; XCTFail("Expected interrupted destination ancestor rename") }
                catch is CancellationError {}
            })
            XCTFail("A changed ancestor cannot retarget the destination after preparation")
        } catch {}
        let entered = await probe.called
        XCTAssertTrue(entered)
        let current = try await a.read(.init(id: before.state.id, kind: .recording))
        XCTAssertEqual(current.state.fields["folder"], before.state.fields["folder"])
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Meeting.mp3")), Data("single synthetic original".utf8))
    }

    func testRelocationRejectsUnknownForeignAndAmbiguousSelections() async throws {
        let (root, a, store) = try await fixture(), (_, b, other) = try await fixture()
        try await store.createFolder(named: "Folder"); try await other.createFolder(named: "Folder")
        let source = try await a.reference(to: "Meeting.mp3"), foreignSource = try await b.reference(to: "Meeting.mp3")
        let catalog = await store.folderCatalog(), otherCatalog = await other.folderCatalog()
        let target = try XCTUnwrap(catalog.references["Folder"]), foreignTarget = try XCTUnwrap(otherCatalog.references["Folder"])
        for change in ["source", "target"] {
            do {
                _ = try await a.relocateRecording(filename: "Meeting.mp3", toFolder: "Folder", changeFolder: true,
                    reference: change == "source" ? foreignSource : source, destinationReference: change == "target" ? foreignTarget : target)
                XCTFail("Foreign reference cannot authorize relocation")
            } catch SharedLibraryCoordinatorError.differentBinding {}
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Unknown"), withIntermediateDirectories: true)
        try await store.loadLibraryMeta()
        do { _ = try await store.moveRecording(filename: "Meeting.mp3", toFolder: "Unknown"); XCTFail("Raw folder grants no identity") }
        catch SharedSidecarError.reloadRequired {}
        try await a.createSharedFolder(named: "Other")
        let views = try await a.snapshots(kinds: [.folder]), extra = try XCTUnwrap(views.first { $0.state.value(for: "name") == .text("Other") })
        _ = try await a.edit(.init(base: extra, changes: [.assign(field: "name", value: .text("Folder"))]))
        do {
            _ = try await a.relocateRecording(filename: "Meeting.mp3", toFolder: "Folder", changeFolder: true, reference: source, destinationReference: target)
            XCTFail("Ambiguous folder cannot receive a recording")
        } catch {
            XCTAssertTrue(error as? SharedLibraryPathError == .unknownPath || error as? SharedLibraryPathError == .ambiguousPath)
        }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Meeting.mp3")), Data("single synthetic original".utf8))
    }

    func testDirectRelocationToOrdinaryFolderCompletes() async throws {
        let (root, a, _) = try await fixture()
        try await a.createSharedFolder(named: "Folder")
        let moved = try await a.relocateRecording(filename: "Meeting.mp3", toFolder: "Folder", changeFolder: true)
        XCTAssertEqual(moved.result, .complete)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Folder/Meeting.mp3")), Data("single synthetic original".utf8))
    }

    func testDestinationIdentityIsBoundAcrossCommitAndRetry() async throws {
        for change in ["rename-reuse", "delete"] {
            let (root, a, store) = try await fixture()
            try await a.createSharedFolder(named: "Folder"); try await store.loadLibraryMeta()
            let folders = await store.folderCatalog(), destination = try XCTUnwrap(folders.references["Folder"])
            let recording = try await a.reference(to: "Meeting.mp3")
            let before = try await a.recording(at: "Meeting.mp3"), probe = RelocationProbe()
            do {
                _ = try await a.relocateRecording(filename: "Meeting.mp3", toFolder: "Folder", changeFolder: true,
                    reference: recording, destinationReference: destination, beforeCommit: {
                        await probe.enter()
                        if change == "delete" { _ = try await a.deleteFolder(named: "Folder", reference: destination) }
                        else {
                            _ = try await a.renameFolder(from: "Folder", to: "Moved Folder", reference: destination)
                            try await a.createSharedFolder(named: "Folder")
                        }
                    })
                XCTFail("Destination identity/path changed before acceptance")
            } catch {
                XCTAssertTrue(error as? SharedLibraryCoordinatorError == .differentBinding || error as? SharedLibraryPathError == .unknownPath
                    || error as? SharedLibraryPathError == .ambiguousPath, "Expected destination refusal, got \(error)")
            }
            let entered = await probe.called
            XCTAssertTrue(entered, "The fixture must reach the destination change at the actual commit boundary")
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Meeting.mp3")), Data("single synthetic original".utf8))
            let current = try await a.recording(at: "Meeting.mp3")
            XCTAssertEqual(current.state.fields["folder"], before.state.fields["folder"], "No destination change is accepted under a stale binding")
        }
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
    func testPeerDeletionDoesNotReclaimACompletedRenameSource() async throws {
        let (root, coordinator, store) = try await fixture()
        _ = try await store.renameRecording(filename: "Meeting.mp3", to: "Renamed")
        let peer = SharedLibraryCoordinator(root: root, writerID: UUID(),
            witnessDirectory: root.deletingLastPathComponent().appendingPathComponent("peer-local"))
        try await peer.requestEnrollment(requestID: UUID(), label: "Peer")
        try await coordinator.refresh(); try await peer.refresh(); try await coordinator.refresh()
        let unrelated = Data("untracked audio at a released path".utf8)
        try unrelated.write(to: root.appendingPathComponent("Meeting.mp3"))
        let pending = try await peer.deleteSharedRecording(filename: "Renamed.mp3")
        XCTAssertEqual(pending.result, .waitingForAcknowledgments)
        try await store.loadLibraryMeta()
        let visible = await store.allRecordings()
        XCTAssertTrue(visible.contains { $0.filename == "Meeting.mp3" }, "Published completion released this path; an old rename recipe must not hide unrelated audio")
        XCTAssertFalse(visible.contains { $0.filename == "Renamed.mp3" })
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Meeting.mp3")), unrelated)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Renamed.mp3").path))
    }

    func testDeletionHidesOriginalRetainedByAnInterruptedRename() async throws {
        let (root, coordinator, store) = try await fixture()
        let original = try await coordinator.recording(at: "Meeting.mp3")
        let interrupted = SharedLibraryCoordinator(root: root, writerID: coordinator.writerID,
            witnessDirectory: root.deletingLastPathComponent().appendingPathComponent("local"),
            afterCommit: { withUnsafeCurrentTask { $0?.cancel() } })
        let moving = Task { try await interrupted.relocateRecording(filename: "Meeting.mp3", title: "Renamed") }
        do { _ = try await moving.value; XCTFail("Fixture must interrupt after semantic acceptance") }
        catch is CancellationError {}
        let renamed = try await coordinator.read(.init(id: original.state.id, kind: .recording))
        XCTAssertEqual(renamed.state.value(for: "title"), .text("Renamed"))
        _ = try await coordinator.edit(.init(base: renamed, changes: [.delete]))
        try await store.loadLibraryMeta()
        let visible = await store.allRecordings()
        XCTAssertFalse(visible.contains { $0.filename == "Meeting.mp3" }, "The accepted path recipe still owns this retained original")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Meeting.mp3").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Renamed.mp3").path))
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
        let (left, a, leftStore) = try await fixture()
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
        try await leftStore.loadLibraryMeta()
        let leftVisible = await leftStore.allRecordings()
        XCTAssertFalse(leftVisible.contains { $0.filename == "Meeting.mp3" }, "Pending physical removal must not make the accepted deletion reappear")
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
        let rightStore = RecordingStore(baseDirectory: right, shared: SharedRecordingMetadataAdapter(coordinator: b))
        try await rightStore.setup()
        let rightVisible = await rightStore.allRecordings()
        XCTAssertFalse(rightVisible.contains { $0.filename == "Meeting.mp3" }, "State-first delivery must hide the retained peer original too")
        try deliverOwner(left, to: right, writer: a.writerID)
        try Data(contentsOf: left.appendingPathComponent("library.json")).write(to: right.appendingPathComponent("library.json"), options: .atomic)
        let mirroredView = try await b.read(entity)
        let awaitingDelivery = try await b.reviewRecordingOperation(id: entity.id)
        XCTAssertNotNil(awaitingDelivery, "Retained peer audio is not completed removal")
        for suffix in [".mp3", ".transcript.json", ".summary.json", ".txt", ".transcript.md", ".summary.md"] {
            let file = right.appendingPathComponent("Meeting" + suffix)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
        do { _ = try await b.resumeRecordingOperation(id: entity.id, expectedCohort: "changed cohort"); XCTFail("Mirrored completion must retain exact reviewed cohort") }
        catch { XCTAssertEqual(error as? SharedLibraryOperationError, .staleAuthority) }
        let mirrored = try await b.resumeRecordingOperation(id: entity.id)
        XCTAssertEqual(mirrored.result, .complete)
        let noPending = try await b.reviewRecordingOperation(id: entity.id)
        XCTAssertNil(noPending)
        let receiptFile = parent.appendingPathComponent("local/Operations/" + mirroredView.libraryID.uuidString + "/" + b.writerID.uuidString + "/" + entity.id.uuidString + ".json")
        var attempted = try SharedOperationReceipt.decode(Data(contentsOf: receiptFile))
        attempted.attempting = true
        let attemptedBytes = try attempted.encoded()
        try attemptedBytes.write(to: receiptFile, options: .atomic)
        let unproven = try await b.resumeRecordingOperation(id: entity.id)
        XCTAssertEqual(unproven.result, .waitingForFile("Meeting.mp3"), "Attempted Trash evidence cannot use the untouched-receipt mirror exception")
        let retainedReview = try await b.reviewRecordingOperation(id: entity.id)
        XCTAssertNotNil(retainedReview, "Attempted missing original still needs review")
        XCTAssertEqual(try Data(contentsOf: receiptFile), attemptedBytes, "Mirrored inspection must never discard attempted physical proof")
    }

    func testKeptDeletionCanApproveNewPeerPlanWithoutRewritingLifecycle() async throws {
        try await checkKeptPeerDeletion(retireBeforeArrival: true)
    }
    func testUnstartedReceiptAfterKeepDoesNotBlockCurrentPeerDeletion() async throws {
        try await checkKeptPeerDeletion(retireBeforeArrival: false)
    }
    private func checkKeptPeerDeletion(retireBeforeArrival: Bool) async throws {
        let (left, a, _) = try await fixture()
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        roots.append(parent); try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let right = parent.appendingPathComponent("library")
        try FileManager.default.copyItem(at: left, to: right)
        let b = SharedLibraryCoordinator(root: right, writerID: UUID(), witnessDirectory: parent.appendingPathComponent("local"), trash: { try FileManager.default.removeItem(at: $0) })
        try await b.requestEnrollment(requestID: UUID(), label: "Peer")
        for _ in 0..<3 {
            try deliverOwner(right, to: left, writer: b.writerID); try await a.refresh()
            try deliverOwner(left, to: right, writer: a.writerID); try await b.refresh()
        }
        let first = try await b.deleteSharedRecording(filename: "Meeting.mp3")
        XCTAssertEqual(first.result, .waitingForAcknowledgments)
        let kept = try await b.resolve(.init(base: first.view, changes: [.restore]))
        if retireBeforeArrival {
            let retired = try await b.reviewRecordingOperation(id: kept.state.id)
            XCTAssertNil(retired, "Keep retires only the unstarted local receipt")
        }
        if retireBeforeArrival { _ = try await b.projectOutputs() }
        // Deliver the kept projection too. State-only arrival must not permit
        // deletion of sidecars whose published provenance is still different.
        for path in ["library.json", "Meeting.transcript.json", "Meeting.summary.json", "Meeting.transcript.md", "Meeting.summary.md", "Meeting.txt"] {
            try Data(contentsOf: right.appendingPathComponent(path)).write(to: left.appendingPathComponent(path), options: .atomic)
        }
        for file in try FileManager.default.contentsOfDirectory(at: right.appendingPathComponent(".docktape/projections"), includingPropertiesForKeys: nil) where file.pathExtension == "json" {
            try Data(contentsOf: file).write(to: left.appendingPathComponent(".docktape/projections/" + file.lastPathComponent), options: .atomic)
        }
        try deliverOwner(right, to: left, writer: b.writerID); try await a.refresh()
        let second = try await a.deleteSharedRecording(filename: "Meeting.mp3")
        XCTAssertEqual(second.result, .waitingForAcknowledgments)
        try deliverOwner(left, to: right, writer: a.writerID); try await b.refresh()
        let entity = SharedEntityIdentity(id: kept.state.id, kind: .recording)
        let before = try await b.read(entity)
        let currentReview = try await b.reviewRecordingOperation(id: kept.state.id)
        let review = try XCTUnwrap(currentReview)
        XCTAssertFalse(review.needsReplanning, "A stale own intent cannot hide the exact current peer plan")
        XCTAssertTrue(review.canAcknowledge, "The peer must approve without publishing another deletion")
        guard review.canAcknowledge else { return }
        try await b.acknowledgeReviewedRecordingOperation(review)
        let reused = try await b.deleteSharedRecording(filename: "Meeting.mp3")
        XCTAssertEqual(reused.result, .complete)
        let after = try await b.read(entity)
        XCTAssertEqual(after.state, before.state, "Reusing accepted deletion does not rewrite lifecycle or either intent")
        try deliverOwner(right, to: left, writer: b.writerID)
        if retireBeforeArrival {
            do { _ = try await a.resumeRecordingOperation(id: entity.id); XCTFail("A newer registry arriving before library.json must wait for its matching projection") }
            catch SharedProjectionWriteError.untracked(let path) { XCTAssertEqual(path, "library.json") }
            XCTAssertTrue(FileManager.default.fileExists(atPath: left.appendingPathComponent("Meeting.mp3").path), "Out-of-order projection delivery preserves the original")
        }
        try Data(contentsOf: right.appendingPathComponent("library.json")).write(to: left.appendingPathComponent("library.json"), options: .atomic)
        let finished = try await a.resumeRecordingOperation(id: entity.id)
        XCTAssertEqual(finished.result, .complete, "Peer acknowledgment remains valid for the initiating plan")
    }

    func testResolvedDeleteCanReviewAndReplanStaleCleanupAfterOfflineEdit() async throws {
        try await checkResolvedLifecycleCleanup(keep: false)
    }
    func testKeepAfterPendingDeletionCanPublishAndUseTheRetainedRecording() async throws {
        try await checkResolvedLifecycleCleanup(keep: true)
    }
    func testResolvedDeletionReplanSurvivesLossOfLocalReceipts() async throws {
        try await checkResolvedLifecycleCleanup(keep: false, restart: true)
    }
    private func checkResolvedLifecycleCleanup(keep: Bool, restart: Bool = false) async throws {
        let (left, a, _) = try await fixture()
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        roots.append(parent); try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let right = parent.appendingPathComponent("library")
        try FileManager.default.copyItem(at: left, to: right)
        let b = SharedLibraryCoordinator(root: right, writerID: UUID(), witnessDirectory: parent.appendingPathComponent("local"))
        try await b.requestEnrollment(requestID: UUID(), label: "Offline peer")
        for _ in 0..<3 {
            try deliverOwner(right, to: left, writer: b.writerID); try await a.refresh()
            try deliverOwner(left, to: right, writer: a.writerID); try await b.refresh()
        }
        let original = try await b.recording(at: "Meeting.mp3")
        let pending = try await a.deleteSharedRecording(filename: "Meeting.mp3")
        XCTAssertEqual(pending.result, .waitingForAcknowledgments)
        _ = try await b.edit(.init(base: original, changes: [.assign(field: "metadata.mode", value: .text("\"Pho\""))]))
        try deliverOwner(right, to: left, writer: b.writerID)
        let entity = SharedEntityIdentity(id: original.state.id, kind: .recording)
        let conflicted = try await a.read(entity)
        XCTAssertEqual(conflicted.state.lifecycle, .conflicted)
        if keep {
            _ = try await a.resolve(.init(base: conflicted, changes: [.restore]))
            _ = try await a.projectOutputs()
            let store = RecordingStore(baseDirectory: left, shared: SharedRecordingMetadataAdapter(coordinator: a))
            try await store.setup()
            let rows = await store.allRecordings()
            XCTAssertEqual(rows.map(\.filename), ["Meeting.mp3"])
            let job = try await a.pinJob(entity)
            await a.finishJob(job)
            XCTAssertEqual(try Data(contentsOf: left.appendingPathComponent("Meeting.mp3")), Data("single synthetic original".utf8))
            let resumed = try await a.resumeRecordingOperation(id: entity.id)
            XCTAssertEqual(resumed.result, .needsReplanning, "Old delete may never remove a kept recording")
            let moved = try await a.relocateRecording(filename: "Meeting.mp3", title: "Kept recording")
            XCTAssertEqual(moved.result, .complete, "Keeping a recording must allow a later independent file operation")
            return
        }
        _ = try await a.resolve(.init(base: conflicted, changes: [.delete]))
        if restart {
            let receipt = left.deletingLastPathComponent().appendingPathComponent("local/Operations/" + conflicted.libraryID.uuidString + "/" + a.writerID.uuidString + "/" + entity.id.uuidString + ".json")
            try FileManager.default.removeItem(at: receipt)
        }
        let owner = restart ? SharedLibraryCoordinator(root: left, writerID: a.writerID,
            witnessDirectory: left.deletingLastPathComponent().appendingPathComponent("local"), trash: { try FileManager.default.removeItem(at: $0) }) : a
        let reviewed = try await owner.reviewRecordingOperation(id: entity.id)
        let review = try XCTUnwrap(reviewed)
        XCTAssertTrue(review.canReplan, "Confirmed deletion needs an actionable new cleanup plan after its old lifecycle receipt becomes stale")
        guard review.canReplan else { return }
        let originalAudio = try Data(contentsOf: left.appendingPathComponent("Meeting.mp3"))
        if restart {
            let held = parent.appendingPathComponent("held-synthetic.mp3")
            try FileManager.default.moveItem(at: left.appendingPathComponent("Meeting.mp3"), to: held)
            do { _ = try await owner.prepareRecordingReplan(review); XCTFail("Missing audio without a local receipt is not completed deletion") }
            catch { XCTAssertTrue(FileManager.default.fileExists(atPath: held.path)) }
            try FileManager.default.moveItem(at: held, to: left.appendingPathComponent("Meeting.mp3"))
        }
        let plan = try await owner.prepareRecordingReplan(review)
        if restart {
            let changedAudio = originalAudio + Data("changed after review".utf8)
            try changedAudio.write(to: left.appendingPathComponent("Meeting.mp3"))
            do { _ = try await owner.applyRecordingReplan(plan); XCTFail("Changed bytes after review must refuse the plan") }
            catch { XCTAssertEqual(try Data(contentsOf: left.appendingPathComponent("Meeting.mp3")), changedAudio) }
            try originalAudio.write(to: left.appendingPathComponent("Meeting.mp3"))
        }
        let accepted = try await owner.applyRecordingReplan(plan)
        XCTAssertEqual(accepted.result, .waitingForAcknowledgments, "Accepting an updated cleanup plan must not require the offline peer's old approval")
        XCTAssertTrue(FileManager.default.fileExists(atPath: left.appendingPathComponent("Meeting.mp3").path))
        try deliverOwner(left, to: right, writer: a.writerID); try await b.refresh()
        try await b.acknowledgeOperation(entity: entity, purpose: .delete)
        try deliverOwner(right, to: left, writer: b.writerID)
        let completed = try await owner.resumeRecordingOperation(id: entity.id)
        XCTAssertEqual(completed.result, .complete)
        XCTAssertFalse(FileManager.default.fileExists(atPath: left.appendingPathComponent("Meeting.mp3").path))
    }

    func testAlreadyDeletedWithoutRecipePublishesDurableCleanupIntent() async throws {
        let (root, a, _) = try await fixture()
        let original = try await a.recording(at: "Meeting.mp3")
        let entity = SharedEntityIdentity(id: original.state.id, kind: .recording)
        let lease = try await a.pinJob(entity)
        let selected = try await a.resolve(.init(base: original, changes: [.delete]))
        let outcome = try await a.prepareReviewedDeletion(selected)
        XCTAssertEqual(outcome.result, .waitingForAcknowledgments, "An active lease prevents the initiating Mac from acknowledging removal")
        let restart = SharedLibraryCoordinator(root: root, writerID: a.writerID,
            witnessDirectory: root.deletingLastPathComponent().appendingPathComponent("restart-local"))
        let pending = try await restart.reviewRecordingOperation(id: entity.id)
        XCTAssertNotNil(pending, "A confirmed delete must publish its cleanup intent, not leave the only recipe in a local receipt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Meeting.mp3").path))
        await a.finishJob(lease)
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
        do { _ = try await store.renameRecording(filename: "Renamed.mp3", to: "Again"); XCTFail("An unseen path cannot renew the displayed reference") }
        catch SharedSidecarError.reloadRequired {}
        try await store.loadLibraryMeta()
        do { _ = try await store.renameRecording(filename: "Renamed.mp3", to: "Again"); XCTFail("Keep unfinished intent recoverable after catalog refresh") }
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
        let reopened = SharedLibraryCoordinator(root: root, writerID: coordinator.writerID,
            witnessDirectory: root.deletingLastPathComponent().appendingPathComponent("local"))
        let resumed = try await reopened.resumeRecordingOperation(id: before.state.id)
        XCTAssertEqual(resumed.result, .complete, "Accepted input must recover without device retransfers")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Interrupted.mp3")), bytes)
        XCTAssertTrue(LibraryFileDiscovery.files(in: root.appendingPathComponent(".docktape/staging"), suffix: ".mp3").isEmpty)
    }
    func testCurrentIntentCannotSupersedeAnUnfinishedReceipt() async throws {
        let (root, coordinator, _) = try await fixture()
        let local = root.deletingLastPathComponent().appendingPathComponent("local")
        let interrupted = SharedLibraryCoordinator(root: root, writerID: coordinator.writerID, witnessDirectory: local,
            afterCommit: { withUnsafeCurrentTask { $0?.cancel() } })
        let store = RecordingStore(baseDirectory: root, shared: SharedRecordingMetadataAdapter(coordinator: interrupted))
        try await store.setup()
        let bytes = Data([0xFF, 0xFB, 0x90, 0x64, 1, 2, 3, 4])
        let task = Task { try await store.importRecording(hdaData: bytes, entry: FileEntry(filename: "Intent.hda", size: UInt32(bytes.count))) }
        do { _ = try await task.value; XCTFail() } catch is CancellationError {}
        let base = try await coordinator.recording(at: "Intent.mp3")
        let entity = SharedEntityIdentity(id: base.state.id, kind: .recording)
        let receipt = local.appendingPathComponent("Operations").appendingPathComponent(base.libraryID.uuidString)
            .appendingPathComponent(coordinator.writerID.uuidString).appendingPathComponent(entity.id.uuidString + ".json")
        let originalReceipt = try Data(contentsOf: receipt)
        let field = "materialization.audio." + coordinator.writerID.uuidString.lowercased()
        let replacement = SharedPreparedAudioIntent(libraryID: base.libraryID, entity: entity, inputRevision: "new intent",
            step: .publishAudio(path: "Intent.mp3", staged: ".docktape/staging/" + entity.id.uuidString + "/" + UUID().uuidString + ".mp3",
                                selectedFingerprint: SharedLibraryOperation.fingerprint(bytes)))
        _ = try await coordinator.edit(.init(base: base, changes: [.assign(field: field, value: .document(try SharedDocument(id: UUID(), json: JSONEncoder().encode(replacement))))]))
        do { _ = try await coordinator.resumeRecordingOperation(id: entity.id); XCTFail("Unfinished accepted work cannot be replaced") }
        catch SharedLibraryOperationError.unfinishedOperation {}
        XCTAssertEqual(try Data(contentsOf: receipt), originalReceipt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Intent.mp3").path))
        let staged = LibraryFileDiscovery.files(in: root.appendingPathComponent(".docktape/staging"), suffix: ".mp3")
        XCTAssertEqual(staged.count, 1)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".docktape/staging/" + staged[0].relativePath)), bytes)
    }

    func testMissingReceiptReconstructionRejectsChangedAndMalformedIntentWithoutConsumingInput() async throws {
        for change in ["title", "fingerprint", "library", "entity", "unsafeStage", "nonAudio", "schema"] {
            let (root, coordinator, _) = try await fixture()
            let local = root.deletingLastPathComponent().appendingPathComponent("local")
            let interrupted = SharedLibraryCoordinator(root: root, writerID: coordinator.writerID, witnessDirectory: local,
                afterCommit: { withUnsafeCurrentTask { $0?.cancel() } })
            let store = RecordingStore(baseDirectory: root, shared: SharedRecordingMetadataAdapter(coordinator: interrupted))
            try await store.setup()
            let bytes = Data([0xFF, 0xFB, 0x90, 0x64, 1, 2, 3, 4])
            let task = Task { try await store.importRecording(hdaData: bytes, entry: FileEntry(filename: "Intent.hda", size: UInt32(bytes.count))) }
            do { _ = try await task.value; XCTFail() } catch is CancellationError {}
            let base = try await coordinator.recording(at: "Intent.mp3")
            let entity = SharedEntityIdentity(id: base.state.id, kind: .recording)
            let receipt = local.appendingPathComponent("Operations").appendingPathComponent(base.libraryID.uuidString)
                .appendingPathComponent(coordinator.writerID.uuidString).appendingPathComponent(entity.id.uuidString + ".json")
            try FileManager.default.removeItem(at: receipt)
            let field = "materialization.audio." + coordinator.writerID.uuidString.lowercased()
            guard case .document(let document)? = base.state.value(for: field) else { XCTFail("Missing accepted intent"); return }
            let intent = try JSONDecoder().decode(SharedPreparedAudioIntent.self, from: document.json)
            var mutation: SharedLibraryMutation
            switch change {
            case "title": mutation = .assign(field: "title", value: .text("Different"))
            case "fingerprint": mutation = .assign(field: "audioFingerprint", value: .text(String(repeating: "f", count: 64)))
            default:
                let step: SharedLibraryOperation.Step
                if change == "nonAudio" { step = .trash(path: "Intent.mp3", fingerprint: SharedLibraryOperation.fingerprint(bytes)) }
                else if change == "unsafeStage" { step = .publishAudio(path: "Intent.mp3", staged: "../outside.mp3", selectedFingerprint: SharedLibraryOperation.fingerprint(bytes)) }
                else { step = intent.step }
                let modified = SharedPreparedAudioIntent(libraryID: change == "library" ? UUID() : intent.libraryID,
                    entity: change == "entity" ? .init(id: UUID(), kind: .recording) : intent.entity,
                    inputRevision: intent.inputRevision, step: step, inputAudioFingerprint: intent.inputAudioFingerprint)
                var data = try JSONEncoder().encode(modified)
                if change == "schema" {
                    var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]); json["schema"] = 2
                    data = try JSONSerialization.data(withJSONObject: json)
                }
                mutation = .assign(field: field, value: .document(try SharedDocument(id: UUID(), json: data)))
            }
            _ = try await coordinator.edit(.init(base: base, changes: [mutation]))
            do { _ = try await coordinator.resumeRecordingOperation(id: entity.id); XCTFail("Changed intent must be reviewed: \(change)") }
            catch { XCTAssertTrue(error is SharedLibraryOperationError, "\(change): \(error)") }
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Intent.mp3").path))
            let staged = LibraryFileDiscovery.files(in: root.appendingPathComponent(".docktape/staging"), suffix: ".mp3")
            XCTAssertEqual(staged.count, 1)
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".docktape/staging/" + staged[0].relativePath)), bytes)
        }
    }

    func testRepairAfterCompletedRenameRecoversCurrentAudioIntent() async throws {
        let (root, coordinator, store) = try await fixture()
        let bytes = Data([0xFF, 0xFB, 0x90, 0x64, 1, 2, 3, 4])
        let entry = FileEntry(filename: "Repair.hda", size: UInt32(bytes.count))
        _ = try await store.importRecording(hdaData: bytes, entry: entry)
        _ = try await store.renameRecording(filename: "Repair.mp3", to: "Renamed repair")
        let before = try await coordinator.recording(at: "Renamed repair.mp3")
        try Data("corrupt".utf8).write(to: root.appendingPathComponent("Renamed repair.mp3"))
        let local = root.deletingLastPathComponent().appendingPathComponent("local")
        let interrupted = SharedLibraryCoordinator(root: root, writerID: coordinator.writerID, witnessDirectory: local,
            afterCommit: { withUnsafeCurrentTask { $0?.cancel() } })
        let repairStore = RecordingStore(baseDirectory: root, shared: SharedRecordingMetadataAdapter(coordinator: interrupted))
        try await repairStore.setup()
        let task = Task { try await repairStore.importRecording(hdaData: bytes, entry: entry) }
        do { _ = try await task.value; XCTFail() } catch is CancellationError {}
        let receipt = local.appendingPathComponent("Operations").appendingPathComponent(before.libraryID.uuidString)
            .appendingPathComponent(coordinator.writerID.uuidString).appendingPathComponent(before.state.id.uuidString + ".json")
        try FileManager.default.removeItem(at: receipt)
        let outcome = try await coordinator.resumeRecordingOperation(id: before.state.id)
        XCTAssertEqual(outcome.result, .complete)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Renamed repair.mp3")), bytes)
    }

    func testMissingFileReceiptRetainsOriginalLifecycleAndSemanticGuard() async throws {
        for change in ["maintenance", "metadata", "renameABA", "deleteABA"] {
            let (root, coordinator, _) = try await fixture()
            let original = try await coordinator.recording(at: "Meeting.mp3")
            let local = root.deletingLastPathComponent().appendingPathComponent("local")
            let interrupted = SharedLibraryCoordinator(root: root, writerID: coordinator.writerID, witnessDirectory: local,
                afterCommit: { withUnsafeCurrentTask { $0?.cancel() } })
            let task = Task {
                if change == "deleteABA" { return try await interrupted.deleteSharedRecording(filename: "Meeting.mp3") }
                return try await interrupted.relocateRecording(filename: "Meeting.mp3", title: "Renamed")
            }
            do { _ = try await task.value; XCTFail() } catch is CancellationError {}
            let accepted = try await coordinator.read(.init(id: original.state.id, kind: .recording))
            let entity = SharedEntityIdentity(id: accepted.state.id, kind: .recording)
            let receipt = local.appendingPathComponent("Operations").appendingPathComponent(accepted.libraryID.uuidString)
                .appendingPathComponent(coordinator.writerID.uuidString).appendingPathComponent(entity.id.uuidString + ".json")
            try FileManager.default.removeItem(at: receipt)
            switch change {
            case "metadata": _ = try await coordinator.edit(.init(base: accepted, changes: [.assign(field: "metadata.mode", value: .text("\"Call\""))]))
            case "renameABA":
                _ = try await coordinator.edit(.init(base: accepted, changes: [.delete]))
                _ = try await coordinator.edit(.init(base: try await coordinator.read(entity), changes: [.restore]))
            case "deleteABA":
                _ = try await coordinator.edit(.init(base: accepted, changes: [.restore]))
                _ = try await coordinator.edit(.init(base: try await coordinator.read(entity), changes: [.delete]))
            default: try await coordinator.refresh()
            }
            let result = try await coordinator.resumeRecordingOperation(id: entity.id)
            XCTAssertEqual(result.result, change == "maintenance" ? .complete : .needsReplanning, change)
            let path = change == "maintenance" ? "Renamed.mp3" : "Meeting.mp3"
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), Data("single synthetic original".utf8))
        }
    }

    func testAcknowledgmentCannotConsumeAChangedReviewedRevision() async throws {
        let (root, coordinator, _) = try await fixture()
        let base = try await coordinator.recording(at: "Meeting.mp3")
        let entity = SharedEntityIdentity(id: base.state.id, kind: .recording)
        let token = try await coordinator.pinJob(entity, audioURL: root.appendingPathComponent("Meeting.mp3"))
        let pending = try await coordinator.deleteSharedRecording(filename: "Meeting.mp3")
        XCTAssertEqual(pending.result, .waitingForAcknowledgments)
        let accepted = try await coordinator.read(entity)
        let reviewed = try SharedLibraryOperation.revision(for: accepted.state)
        await coordinator.finishJob(token)
        _ = try await coordinator.edit(.init(base: accepted, changes: [.restore]))
        _ = try await coordinator.edit(.init(base: try await coordinator.read(entity), changes: [.delete]))
        do { try await coordinator.acknowledgeOperation(entity: entity, purpose: .delete, expectedRevision: reviewed); XCTFail("Old review cannot consent to a new deletion") }
        catch SharedLibraryOperationError.staleAuthority {}
        let beforeApproval = try await coordinator.operationAuthority(entity: entity, paths: [])
        XCTAssertTrue(beforeApproval.acknowledgments.isEmpty)
        let current = try SharedLibraryOperation.revision(for: beforeApproval.state)
        try await coordinator.acknowledgeOperation(entity: entity, purpose: .delete, expectedRevision: current)
        let approved = try await coordinator.operationAuthority(entity: entity, paths: [])
        XCTAssertEqual(approved.acknowledgments.count, 1)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Meeting.mp3")), Data("single synthetic original".utf8))
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

    private enum ReviewStop: Error { case interrupted }
    func testReviewedResumeCompletesActualPartialMove() async throws {
        let (root, coordinator, _) = try await fixture()
        let entity = SharedEntityIdentity(id: try await coordinator.reference(to: "Meeting.mp3").entityID, kind: .recording)
        do { _ = try await coordinator.relocateRecording(filename: "Meeting.mp3", title: "Reviewed", afterMutation: { _ in throw ReviewStop.interrupted }); XCTFail() }
        catch ReviewStop.interrupted {}
        let value = try await coordinator.reviewRecordingOperation(id: entity.id)
        let review = try XCTUnwrap(value)
        XCTAssertTrue(review.canResume)
        XCTAssertTrue(review.paths.contains("Meeting.mp3")); XCTAssertTrue(review.paths.contains("Reviewed.mp3"))
        let result = try await coordinator.resumeReviewedRecordingOperation(review)
        XCTAssertEqual(result.result, .complete)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Reviewed.mp3")), Data("single synthetic original".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Meeting.transcript.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Reviewed.transcript.json").path))
        let finished = try await coordinator.reviewRecordingOperation(id: entity.id)
        XCTAssertNil(finished, "Completed receipt is not pending work")
    }
    func testReviewedResumeCannotConsumeChangedMetadata() async throws {
        let (root, coordinator, _) = try await fixture()
        let entity = SharedEntityIdentity(id: try await coordinator.reference(to: "Meeting.mp3").entityID, kind: .recording)
        do { _ = try await coordinator.relocateRecording(filename: "Meeting.mp3", title: "Reviewed", afterMutation: { _ in throw ReviewStop.interrupted }); XCTFail() }
        catch ReviewStop.interrupted {}
        let value = try await coordinator.reviewRecordingOperation(id: entity.id)
        let review = try XCTUnwrap(value)
        _ = try await coordinator.edit(.init(base: try await coordinator.read(entity), changes: [.assign(field: "metadata.mode", value: .text("\"Wip\""))]))
        do { _ = try await coordinator.resumeReviewedRecordingOperation(review); XCTFail("A click cannot consume changes arriving after review") }
        catch SharedLibraryCoordinatorError.staleReview {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Meeting.transcript.json").path))
        let newValue = try await coordinator.reviewRecordingOperation(id: entity.id)
        let fresh = try XCTUnwrap(newValue)
        XCTAssertTrue(fresh.needsReplanning); XCTAssertFalse(fresh.canResume)
    }
    func testReviewedAcknowledgmentPinsMembershipAndDoesNotApproveActiveWork() async throws {
        let (root, coordinator, _) = try await fixture()
        let entity = SharedEntityIdentity(id: try await coordinator.reference(to: "Meeting.mp3").entityID, kind: .recording)
        let job = try await coordinator.pinJob(entity)
        _ = try await coordinator.deleteSharedRecording(filename: "Meeting.mp3")
        let busyValue = try await coordinator.reviewRecordingOperation(id: entity.id)
        let busy = try XCTUnwrap(busyValue)
        XCTAssertFalse(busy.canAcknowledge)
        await coordinator.finishJob(job)
        let idleValue = try await coordinator.reviewRecordingOperation(id: entity.id)
        let idle = try XCTUnwrap(idleValue)
        XCTAssertTrue(idle.canAcknowledge)
        let other = SharedLibraryCoordinator(root: root, writerID: UUID(), witnessDirectory: root.deletingLastPathComponent().appendingPathComponent("other-local"))
        try await other.requestEnrollment(requestID: UUID(), label: "Joining Mac")
        do { try await coordinator.acknowledgeReviewedRecordingOperation(idle); XCTFail("A reviewed cohort cannot silently include a new participating Mac") }
        catch SharedLibraryOperationError.staleAuthority {}
        let permission = try await coordinator.operationAuthority(entity: entity, paths: [])
        XCTAssertTrue(permission.acknowledgments.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Meeting.mp3").path))
    }

    func testLostReceiptAndChangedOriginalPlanStillAppearForReview() async throws {
        let (root, coordinator, _) = try await fixture()
        let entity = SharedEntityIdentity(id: try await coordinator.reference(to: "Meeting.mp3").entityID, kind: .recording)
        do { _ = try await coordinator.relocateRecording(filename: "Meeting.mp3", title: "Reviewed", afterMutation: { _ in throw ReviewStop.interrupted }); XCTFail() }
        catch ReviewStop.interrupted {}
        let base = try await coordinator.read(entity)
        let receipt = root.deletingLastPathComponent().appendingPathComponent("local/Operations/\(base.libraryID.uuidString)/\(coordinator.writerID.uuidString)/\(entity.id.uuidString).json")
        try FileManager.default.removeItem(at: receipt)
        _ = try await coordinator.edit(.init(base: base, changes: [.assign(field: "metadata.mode", value: .text("\"Wip\""))]))
        let value = try await coordinator.reviewRecordingOperation(id: entity.id)
        let review = try XCTUnwrap(value, "The accepted shared recipe remains visible even if its local receipt was lost")
        XCTAssertTrue(review.needsReplanning); XCTAssertFalse(review.canResume)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Reviewed.mp3").path))
    }

    func testReviewedApprovalThenResumeCompletesDeletion() async throws {
        let (root, coordinator, _) = try await fixture()
        let entity = SharedEntityIdentity(id: try await coordinator.reference(to: "Meeting.mp3").entityID, kind: .recording)
        let job = try await coordinator.pinJob(entity)
        _ = try await coordinator.deleteSharedRecording(filename: "Meeting.mp3")
        await coordinator.finishJob(job)
        let beforeValue = try await coordinator.reviewRecordingOperation(id: entity.id)
        let before = try XCTUnwrap(beforeValue)
        XCTAssertTrue(before.canAcknowledge); XCTAssertFalse(before.canResume)
        try await coordinator.acknowledgeReviewedRecordingOperation(before)
        let approvedValue = try await coordinator.reviewRecordingOperation(id: entity.id)
        let approved = try XCTUnwrap(approvedValue)
        XCTAssertTrue(approved.canResume); XCTAssertFalse(approved.canAcknowledge)
        let outcome = try await coordinator.resumeReviewedRecordingOperation(approved)
        XCTAssertEqual(outcome.result, .complete)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Meeting.mp3").path))
        XCTAssertEqual(try Data(contentsOf: root.deletingLastPathComponent().appendingPathComponent("recycled/Meeting.mp3")), Data("single synthetic original".utf8))
    }

    func testPartialMoveRetainsIntermediateIdentityAfterAnotherSemanticRename() async throws {
        let (root, coordinator, _) = try await fixture()
        let entity = SharedEntityIdentity(id: try await coordinator.reference(to: "Meeting.mp3").entityID, kind: .recording)
        do { _ = try await coordinator.relocateRecording(filename: "Meeting.mp3", title: "Intermediate", afterMutation: { _ in throw ReviewStop.interrupted }); XCTFail() }
        catch ReviewStop.interrupted {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Intermediate.mp3").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Meeting.transcript.json").path))
        _ = try await coordinator.edit(.init(base: try await coordinator.read(entity), changes: [.assign(field: "title", value: .text("Final"))]))
        let permission = try await coordinator.operationAuthority(entity: entity, paths: ["Intermediate.mp3", "Meeting.transcript.json", "Final.mp3"])
        XCTAssertEqual(permission.pathOwners["Intermediate.mp3"], [entity.id], "Accepted recipe reserves intermediate paths even after another title edit")
        do { _ = try await coordinator.projectOutputs(); XCTFail("Do not publish over surviving intermediate audio") }
        catch SharedLibraryOperationError.unfinishedOperation {}
    }

    func testConfirmedCompletedMoveDoesNotHydrateAudioForMetadataPublication() async throws {
        let (root, coordinator, store) = try await fixture()
        _ = try await store.renameRecording(filename: "Meeting.mp3", to: "Moved")
        let entity = SharedEntityIdentity(id: try await coordinator.reference(to: "Moved.mp3").entityID, kind: .recording)
        let changedBytes = Data("external audio change; metadata publication is not an integrity scan".utf8)
        try changedBytes.write(to: root.appendingPathComponent("Moved.mp3"), options: .atomic)
        _ = try await coordinator.edit(.init(base: try await coordinator.read(entity), changes: [.assign(field: "metadata.mode", value: .text("\"Wip\""))]))
        _ = try await coordinator.projectOutputs()
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Moved.mp3")), changedBytes)
    }
    private func completedUnpublishedMove() async throws -> (URL, SharedLibraryCoordinator) {
        let (root, coordinator, _) = try await fixture()
        let reference = try await coordinator.reference(to: "Meeting.mp3")
        do { _ = try await coordinator.relocateRecording(filename: "Meeting.mp3", title: "Moved", afterMutation: { _ in throw ReviewStop.interrupted }); XCTFail() }
        catch ReviewStop.interrupted {}
        let entity = SharedEntityIdentity(id: reference.entityID, kind: .recording)
        let library = try await coordinator.read(entity).libraryID
        let receipts = root.deletingLastPathComponent().appendingPathComponent("local/Operations/\(library.uuidString)/\(coordinator.writerID.uuidString)")
        let reader = try await coordinator.makeMaterializer(entity: entity, paths: [], receipts: receipts)
        let value = try await reader.progress(entity: entity, libraryID: library)
        let progress = try XCTUnwrap(value)
        let materializer = try await coordinator.makeMaterializer(entity: entity, paths: Array(progress.operation.canonicalPaths), receipts: receipts)
        let outcome = try await materializer.replay(progress.operation)
        XCTAssertEqual(outcome, .complete)
        return (root, coordinator)
    }
    func testCompletionPublicationRechecksLateSurvivingAlias() async throws {
        let (root, coordinator) = try await completedUnpublishedMove()
        let late = Data("late original-path arrival".utf8)
        do { _ = try await coordinator.projectOutputs(beforeWrite: { try? late.write(to: root.appendingPathComponent("Meeting.mp3"), options: .atomic) }); XCTFail("Publication must recheck physical aliases inside coordination") }
        catch SharedLibraryOperationError.unfinishedOperation {}
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Meeting.mp3")), late)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Moved.mp3")), Data("single synthetic original".utf8))
    }
    func testCompletionPublicationRechecksChangedAudio() async throws {
        let (root, coordinator) = try await completedUnpublishedMove()
        let changed = Data("audio changed while waiting for publication".utf8)
        do { _ = try await coordinator.projectOutputs(beforeWrite: { try? changed.write(to: root.appendingPathComponent("Moved.mp3"), options: .atomic) }); XCTFail("Do not publish a completion proof for changed bytes") }
        catch SharedLibraryOperationError.contentChanged(let path) { XCTAssertEqual(path, "Moved.mp3") }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Moved.mp3")), changed)
    }

    private func pendingChangedMove(directory: URL? = nil) async throws -> (URL, SharedLibraryCoordinator, SharedRecordingOperationReview) {
        let (root, coordinator, _) = try await fixture(directory: directory)
        let entity = SharedEntityIdentity(id: try await coordinator.reference(to: "Meeting.mp3").entityID, kind: .recording)
        do { _ = try await coordinator.relocateRecording(filename: "Meeting.mp3", title: "Intermediate", afterMutation: { _ in throw ReviewStop.interrupted }); XCTFail() }
        catch ReviewStop.interrupted {}
        _ = try await coordinator.edit(.init(base: try await coordinator.read(entity), changes: [.assign(field: "title", value: .text("Final"))]))
        let value = try await coordinator.reviewRecordingOperation(id: entity.id)
        return (root, coordinator, try XCTUnwrap(value))
    }
    func testExplicitUpdatedPlanMovesAllSurvivingFilesToReviewedDestination() async throws {
        let (root, coordinator, original) = try await pendingChangedMove()
        let prepared = try await coordinator.prepareRecordingReplan(original)
        XCTAssertEqual(prepared.destination, "Final.mp3")
        XCTAssertTrue(prepared.sources.contains("Intermediate.mp3"))
        XCTAssertTrue(prepared.sources.contains("Meeting.transcript.json"))
        let result = try await coordinator.applyRecordingReplan(prepared)
        XCTAssertEqual(result.result, .complete); XCTAssertNil(result.projectionError)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Final.mp3")), Data("single synthetic original".utf8))
        for name in ["Meeting.mp3", "Intermediate.mp3", "Meeting.transcript.json", "Intermediate.transcript.json"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Final.transcript.json").path))
        let current = try await coordinator.reference(to: "Final.mp3")
        XCTAssertEqual(current.entityID, original.id)
    }
    func testUpdatedPlanRefusesUnseenSemanticAndPhysicalChanges() async throws {
        let (root, coordinator, original) = try await pendingChangedMove()
        let prepared = try await coordinator.prepareRecordingReplan(original)
        let changed = Data("unseen audio edit".utf8)
        try changed.write(to: root.appendingPathComponent("Intermediate.mp3"), options: .atomic)
        do { _ = try await coordinator.applyRecordingReplan(prepared); XCTFail("Reviewed fingerprints cannot silently change") } catch {}
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Intermediate.mp3")), changed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Final.mp3").path))
        try Data("single synthetic original".utf8).write(to: root.appendingPathComponent("Intermediate.mp3"), options: .atomic)
        _ = try await coordinator.edit(.init(base: try await coordinator.read(.init(id: original.id, kind: .recording)), changes: [.assign(field: "title", value: .text("Another"))]))
        do { _ = try await coordinator.applyRecordingReplan(prepared); XCTFail("A new destination requires another review") }
        catch SharedLibraryCoordinatorError.staleReview {}
    }
    func testUpdatedPlanDoesNotAdoptUnprovenDestinationWithIdenticalBytes() async throws {
        let (root, coordinator, original) = try await pendingChangedMove()
        try Data("single synthetic original".utf8).write(to: root.appendingPathComponent("Final.mp3"), options: .atomic)
        do { _ = try await coordinator.prepareRecordingReplan(original); XCTFail("Byte equality cannot establish a destination's provenance") }
        catch SharedLibraryOperationError.pathConflict(let path) { XCTAssertEqual(path, "Final.mp3") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Intermediate.mp3").path))
    }

    func testAcceptedUpdatedPlanRecoversAfterCancellationBeforeReceiptReplacement() async throws {
        let (root, original, review) = try await pendingChangedMove()
        let prepared = try await original.prepareRecordingReplan(review)
        let local = root.deletingLastPathComponent().appendingPathComponent("local")
        let cancelled = SharedLibraryCoordinator(root: root, writerID: original.writerID, witnessDirectory: local,
            afterCommit: { withUnsafeCurrentTask { $0?.cancel() } })
        let task = Task { try await cancelled.applyRecordingReplan(prepared) }
        do { _ = try await task.value; XCTFail() } catch is CancellationError {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Intermediate.mp3").path))
        let reopened = SharedLibraryCoordinator(root: root, writerID: original.writerID, witnessDirectory: local)
        let result = try await reopened.resumeRecordingOperation(id: review.id)
        XCTAssertEqual(result.result, .complete); XCTAssertNil(result.projectionError)
        let again = try await reopened.resumeRecordingOperation(id: review.id)
        XCTAssertEqual(again.result, .complete)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Final.mp3")), Data("single synthetic original".utf8))
    }
    func testUpdatedPlanRefusesLateUnreviewedDestinationAfterAcceptance() async throws {
        let (root, original, review) = try await pendingChangedMove()
        let prepared = try await original.prepareRecordingReplan(review)
        let bytes = Data("single synthetic original".utf8)
        let raced = SharedLibraryCoordinator(root: root, writerID: original.writerID,
            witnessDirectory: root.deletingLastPathComponent().appendingPathComponent("local"),
            afterCommit: { try? bytes.write(to: root.appendingPathComponent("Final.mp3"), options: .atomic) })
        do { _ = try await raced.applyRecordingReplan(prepared); XCTFail("A post-acceptance matching file is not a reviewed destination") }
        catch SharedLibraryOperationError.pathConflict(let path) { XCTAssertEqual(path, "Final.mp3") }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Intermediate.mp3")), bytes)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Final.mp3")), bytes)
    }
    func testLateRetainedAliasRemainsVisibleAfterReplannedStepsComplete() async throws {
        let (root, coordinator, review) = try await pendingChangedMove()
        let prepared = try await coordinator.prepareRecordingReplan(review)
        let raced = SharedLibraryCoordinator(root: root, writerID: coordinator.writerID,
            witnessDirectory: root.deletingLastPathComponent().appendingPathComponent("local"),
            afterCommit: { withUnsafeCurrentTask { $0?.cancel() } })
        do { _ = try await Task { try await raced.applyRecordingReplan(prepared) }.value; XCTFail() } catch is CancellationError {}
        // Another accepted original path arrives after the replacement was prepared.
        let bytes = Data("single synthetic original".utf8)
        try bytes.write(to: root.appendingPathComponent("Meeting.mp3"), options: .atomic)
        let result = try await coordinator.resumeRecordingOperation(id: review.id)
        XCTAssertEqual(result.result, .needsReplanning, "The original receipt must not drop a newly surviving owned path")
        let value = try await coordinator.reviewRecordingOperation(id: review.id)
        XCTAssertNotNil(value, "A newly surviving original stays actionable")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Meeting.mp3")), bytes)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Intermediate.mp3")), bytes)
        let next = try XCTUnwrap(value)
        let updated = try await coordinator.prepareRecordingReplan(next)
        let completed = try await coordinator.applyRecordingReplan(updated)
        XCTAssertEqual(completed.result, .complete); XCTAssertNil(completed.projectionError)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Final.mp3")), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Meeting.mp3").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Intermediate.mp3").path))
    }

    func testCompletedReplanReceiptWithLateAliasRemainsActionable() async throws {
        let (root, coordinator, review) = try await pendingChangedMove()
        let prepared = try await coordinator.prepareRecordingReplan(review)
        let local = root.deletingLastPathComponent().appendingPathComponent("local")
        let cancelled = SharedLibraryCoordinator(root: root, writerID: coordinator.writerID, witnessDirectory: local,
            afterCommit: { withUnsafeCurrentTask { $0?.cancel() } })
        do { _ = try await Task { try await cancelled.applyRecordingReplan(prepared) }.value; XCTFail() } catch is CancellationError {}
        let intermediateReview = try await coordinator.reviewRecordingOperation(id: review.id)
        let accepted = try XCTUnwrap(intermediateReview)
        let receipts = local.appendingPathComponent("Operations/\(accepted.base.libraryID.uuidString)/\(coordinator.writerID.uuidString)")
        let materializer = try await coordinator.makeMaterializer(entity: accepted.operation.entity, paths: Array(accepted.operation.canonicalPaths), receipts: receipts)
        let done = try await materializer.replay(accepted.operation)
        XCTAssertEqual(done, .complete)
        try Data("single synthetic original".utf8).write(to: root.appendingPathComponent("Meeting.mp3"), options: .atomic)
        let value = try await coordinator.reviewRecordingOperation(id: review.id)
        let pending = try XCTUnwrap(value, "Completed local steps are not completed publication when an old alias survives")
        XCTAssertTrue(pending.needsReplanning)
        let next = try await coordinator.prepareRecordingReplan(pending)
        let result = try await coordinator.applyRecordingReplan(next)
        XCTAssertEqual(result.result, .complete); XCTAssertNil(result.projectionError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Meeting.mp3").path))
    }

    func testUpdatedPlanRefusesChangedAncestorLocation() async throws {
        let (root, coordinator, store) = try await fixture()
        try await store.createFolder(named: "Archive")
        _ = try await store.moveRecording(filename: "Meeting.mp3", toFolder: "Archive")
        let entity = SharedEntityIdentity(id: try await coordinator.reference(to: "Archive/Meeting.mp3").entityID, kind: .recording)
        do { _ = try await coordinator.relocateRecording(filename: "Archive/Meeting.mp3", title: "Intermediate", afterMutation: { _ in throw ReviewStop.interrupted }); XCTFail() }
        catch ReviewStop.interrupted {}
        _ = try await coordinator.edit(.init(base: try await coordinator.read(entity), changes: [.assign(field: "title", value: .text("Final"))]))
        let value = try await coordinator.reviewRecordingOperation(id: entity.id)
        let review = try XCTUnwrap(value)
        let prepared = try await coordinator.prepareRecordingReplan(review)
        let folders = try await coordinator.snapshots(kinds: [.folder])
        let folder = try XCTUnwrap(folders.first)
        _ = try await coordinator.edit(.init(base: folder, changes: [.assign(field: "name", value: .text("Changed"))]))
        do { _ = try await coordinator.applyRecordingReplan(prepared); XCTFail("An ancestor rename changes the reviewed destination without changing this recording") }
        catch SharedLibraryCoordinatorError.staleReview {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Archive/Intermediate.mp3").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Archive/Final.mp3").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Changed/Final.mp3").path))
    }
    func testUpdatedPlanRefusesDestinationAppearingAtCommitBoundary() async throws {
        let (root, coordinator, review) = try await pendingChangedMove()
        let prepared = try await coordinator.prepareRecordingReplan(review)
        let before = try await coordinator.read(.init(id: review.id, kind: .recording))
        let bytes = Data("single synthetic original".utf8)
        do {
            _ = try await coordinator.applyRecordingReplan(prepared, beforeCommit: {
                try bytes.write(to: root.appendingPathComponent("Final.mp3"), options: .atomic)
            })
            XCTFail("No new receipt or semantic recipe may consume an unreviewed destination")
        } catch SharedLibraryOperationError.contentChanged(let path) { XCTAssertEqual(path, "Final.mp3") }
        let after = try await coordinator.read(.init(id: review.id, kind: .recording))
        XCTAssertEqual(after.fingerprint, before.fingerprint)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Intermediate.mp3")), bytes)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Final.mp3")), bytes)
    }
    func testOldFileIntentAndReceiptDecodeWithoutReplanFields() throws {
        let entity = SharedEntityIdentity(id: UUID(), kind: .recording)
        let hash = SharedLibraryOperation.fingerprint(Data("original".utf8))
        let intent = SharedAcceptedFileIntent(schema: 1, libraryID: UUID(), entity: entity,
            inputRevision: hash, guardRevision: hash, steps: [.move(source: "Old.mp3", destination: "New.mp3", fingerprint: hash)])
        let encoded = try JSONEncoder().encode(intent)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(object["retainedFiles"]); XCTAssertNil(object["replacesOperationID"]); XCTAssertNil(object["reviewedExistingDestinations"])
        let old = try JSONDecoder().decode(SharedAcceptedFileIntent.self, from: encoded)
        XCTAssertNil(old.retainedFiles); XCTAssertNil(old.replacesOperationID); XCTAssertNil(old.reviewedExistingDestinations)
        let operation = try SharedLibraryOperation(libraryID: intent.libraryID, entity: entity,
            inputRevision: hash, outputRevision: hash, steps: intent.steps)
        let legacy = try JSONDecoder().decode(SharedLibraryOperation.self, from: JSONEncoder().encode(operation))
        XCTAssertNil(legacy.reviewedExistingDestinations)
        XCTAssertEqual(legacy, operation)
    }

    private actor ResolutionMutations {
        private(set) var count = 0
        func next() -> Int { count += 1; return count }
    }
    func testReferenceResolutionRetriesOneUnrelatedEditBeforeStartingWork() async throws {
        let (_, coordinator, _) = try await fixture()
        let reference = try await coordinator.reference(to: "Meeting.mp3")
        let mutations = ResolutionMutations()
        let path = try await coordinator.resolve(reference, beforeValidation: {
            if await mutations.next() == 1 {
                let view = try await coordinator.read(.init(id: reference.entityID, kind: .recording))
                _ = try await coordinator.edit(.init(base: view, changes: [.assign(field: "metadata.mode", value: .text("\"Rec\""))]))
            }
        })
        XCTAssertEqual(path, "Meeting.mp3")
        let attempts = await mutations.count
        XCTAssertEqual(attempts, 2, "Read preparation retries a changed snapshot before pinning work")
    }
    func testReferenceResolutionRefusesAnUnpublishedAncestorRename() async throws {
        let (_, coordinator, store) = try await fixture()
        try await store.createFolder(named: "Archive")
        _ = try await store.moveRecording(filename: "Meeting.mp3", toFolder: "Archive")
        let reference = try await coordinator.reference(to: "Archive/Meeting.mp3")
        let folders = try await coordinator.snapshots(kinds: [.folder])
        let folder = try XCTUnwrap(folders.first)
        let mutations = ResolutionMutations()
        do {
            _ = try await coordinator.resolve(reference, beforeValidation: {
                if await mutations.next() == 1 {
                    _ = try await coordinator.edit(.init(base: folder, changes: [.assign(field: "name", value: .text("Unpublished"))]))
                }
            })
            XCTFail("A parent changed without changing this recording's state; the old physical location must not be returned")
        } catch SharedLibraryOperationError.unfinishedOperation {}
    }
    func testReferenceResolutionBoundsRetriesDuringContinuousChanges() async throws {
        let (_, coordinator, _) = try await fixture()
        let reference = try await coordinator.reference(to: "Meeting.mp3")
        let mutations = ResolutionMutations()
        do {
            _ = try await coordinator.resolve(reference, beforeValidation: {
                let number = await mutations.next()
                let view = try await coordinator.read(.init(id: reference.entityID, kind: .recording))
                _ = try await coordinator.edit(.init(base: view, changes: [.assign(field: "metadata.mode", value: .text("edit-\(number)"))]))
            })
            XCTFail("Continuously changing state must remain pending")
        } catch SharedLibraryCoordinatorError.staleJob {}
        let attempts = await mutations.count
        XCTAssertEqual(attempts, 3)
    }

    func testUpdatedPlanUnderExplicitPrivateTmpRootUsesItsCoordinatedDirectory() async throws {
        let requested = URL(fileURLWithPath: "/private/tmp/DockTapeReplanAlias-" + UUID().uuidString + "/data")
        roots.append(requested.deletingLastPathComponent())
        try FileManager.default.createDirectory(at: requested, withIntermediateDirectories: true)
        let (root, coordinator, review) = try await pendingChangedMove(directory: requested.standardizedFileURL.resolvingSymlinksInPath())
        let prepared = try await coordinator.prepareRecordingReplan(review)
        let result = try await coordinator.applyRecordingReplan(prepared)
        XCTAssertEqual(result.result, .complete); XCTAssertNil(result.projectionError)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Final.mp3")), Data("single synthetic original".utf8))
    }

    func testIDBoundStoreDeletionSurvivesKnownPublicationBetweenCanonicalAndRegistryReads() async throws {
        let (root, owner, _) = try await fixture()
        let reference = try await owner.reference(to: "Meeting.mp3")
        let stage = ResolutionMutations()
        let local = root.deletingLastPathComponent().appendingPathComponent("local")
        let recycled = root.deletingLastPathComponent().appendingPathComponent("race-recycled")
        let reader = SharedLibraryCoordinator(root: root, writerID: owner.writerID, witnessDirectory: local, afterPublishedLibraryRead: {
            if await stage.next() == 1 {
                let view = try await owner.read(.init(id: reference.entityID, kind: .recording))
                _ = try await owner.edit(.init(base: view, changes: [.assign(field: "metadata.mode", value: .text("\"Rec\""))]))
                _ = try await owner.projectOutputs()
            }
        }, trash: { url in
            try FileManager.default.createDirectory(at: recycled, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: recycled.appendingPathComponent(url.lastPathComponent))
        })
        let store = RecordingStore(baseDirectory: root, shared: SharedRecordingMetadataAdapter(coordinator: reader))
        try await store.setup()
        try await store.deleteRecordingAndSidecars(filename: "Meeting.mp3", reference: reference)
        let outcome = await store.sharedOperation
        XCTAssertEqual(outcome?.result, .complete); XCTAssertNil(outcome?.projectionError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Meeting.mp3").path))
        XCTAssertEqual(try Data(contentsOf: recycled.appendingPathComponent("Meeting.mp3")), Data("single synthetic original".utf8))
    }
    func testIDBoundStoreDeletionPreservesExternalLibraryArrivingDuringRead() async throws {
        let (root, owner, _) = try await fixture()
        let reference = try await owner.reference(to: "Meeting.mp3")
        let stage = ResolutionMutations()
        let external = Data("{\"External.mp3\":{}}".utf8)
        let reader = SharedLibraryCoordinator(root: root, writerID: owner.writerID,
            witnessDirectory: root.deletingLastPathComponent().appendingPathComponent("local"), afterPublishedLibraryRead: {
                if await stage.next() == 1 { try external.write(to: root.appendingPathComponent("library.json"), options: .atomic) }
            }, trash: { _ in XCTFail("An external library must block before touching originals") })
        let store = RecordingStore(baseDirectory: root, shared: SharedRecordingMetadataAdapter(coordinator: reader))
        try await store.setup()
        do { try await store.deleteRecordingAndSidecars(filename: "Meeting.mp3", reference: reference); XCTFail() }
        catch SharedProjectionWriteError.untracked(let path) { XCTAssertEqual(path, "library.json") }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("library.json")), external)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Meeting.mp3")), Data("single synthetic original".utf8))
        let view = try await owner.read(.init(id: reference.entityID, kind: .recording))
        XCTAssertEqual(view.state.lifecycle, .alive)
    }

}
