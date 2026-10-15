// © 2026 High Gain Design. All rights reserved.
import XCTest
@testable import HiDockKit

final class SharedMetadataStoreTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() { for root in roots { try? FileManager.default.removeItem(at: root) } }
    private func fixture() async throws -> (URL, SharedLibraryCoordinator) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        roots.append(root)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Folder"), withIntermediateDirectories: true)
        for name in ["One.mp3", "Folder/One.mp3"] { try Data("synthetic".utf8).write(to: root.appendingPathComponent(name)) }
        let original = RecordingStore(baseDirectory: root)
        try await original.setup()
        try await original.setMeta(mode: "Rec", deviceFilename: "first.hda", for: "One.mp3")
        try await original.setMeta(mode: "Pho", deviceFilename: "second.hda", for: "Folder/One.mp3")
        let coordinator = SharedLibraryCoordinator(root: root, writerID: UUID())
        _ = try await coordinator.enable()
        return (root, coordinator)
    }
    private actor CatalogObservation {
        var latest: [RecordingMetadata] = []
        var callbacks = 0
        var finished = false
        func accept(_ entries: [RecordingMetadata]) { latest = entries; callbacks += 1 }
        func entries() -> [RecordingMetadata] { latest }
        func count() -> Int { callbacks }
        func finish() { finished = true }
        func isFinished() -> Bool { finished }
    }
    func testProgressiveCatalogExposesResidentNestedRecordingBeforeUnrelatedHead() async throws {
        try await checkProgressiveCatalog(deleted: false)
    }
    func testProgressiveCatalogDoesNotExposeRetainedDeletedOrUnknownAudio() async throws {
        try await checkProgressiveCatalog(deleted: true)
    }
    private func checkProgressiveCatalog(deleted: Bool) async throws {
        let (root, coordinator) = try await fixture()
        let a = try await coordinator.recording(at: "One.mp3")
        if deleted { _ = try await coordinator.edit(.init(base: a, changes: [.delete])) }
        try Data("unknown raw audio".utf8).write(to: root.appendingPathComponent("Unknown.mp3"))
        let store = RecordingStore(baseDirectory: root, shared: SharedRecordingMetadataAdapter(coordinator: coordinator))
        let unopened = await store.allRecordings()
        XCTAssertTrue(unopened.isEmpty, "An uninitialized shared catalog must not infer identities/lifecycle from physical audio")
        let head = root.appendingPathComponent(".docktape/records/" + a.state.id.uuidString.lowercased() + "/" + coordinator.writerID.uuidString.lowercased() + ".json")
        let started = expectation(description: "A owner head held")
        let release = DispatchSemaphore(value: 0)
        let holder = Task {
            try await CoordinatedFileAccess().withWrite(at: head) { _ in
                started.fulfill()
                _ = release.wait(timeout: .now() + 8)
            }
        }
        await fulfillment(of: [started], timeout: 1)
        let observation = CatalogObservation()
        let loading = Task { try await store.setup(onProgress: { await observation.accept(await store.allRecordings()) }) }
        for _ in 0..<150 {
            if await observation.entries().contains(where: { $0.filename == "Folder/One.mp3" }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let partial = await observation.entries()
        release.signal(); try await holder.value; try await loading.value
        XCTAssertEqual(partial.map(\.filename), ["Folder/One.mp3"], "Only resident B with its available ancestor graph belongs in the partial catalog")
        XCTAssertNotNil(partial.first?.reference)
        let final = await store.allRecordings()
        XCTAssertEqual(final.contains { $0.filename == "One.mp3" }, !deleted)
        XCTAssertTrue(final.contains { $0.filename == "Unknown.mp3" }, "A complete catalog retains established raw-audio discovery")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("One.mp3")), Data("synthetic".utf8))
    }

    func testProgressiveCatalogPreservesResidentEntriesWhenAnotherHeadIsInvalid() async throws {
        let (root, coordinator) = try await fixture()
        let a = try await coordinator.recording(at: "One.mp3")
        let head = root.appendingPathComponent(".docktape/records/" + a.state.id.uuidString.lowercased() + "/" + coordinator.writerID.uuidString.lowercased() + ".json")
        let original = try Data(contentsOf: head)
        defer { try? original.write(to: head, options: .atomic) }
        try Data("Invalid authoritative fixture".utf8).write(to: head, options: .atomic)
        let store = RecordingStore(baseDirectory: root, shared: SharedRecordingMetadataAdapter(coordinator: coordinator))
        let observation = CatalogObservation()
        var failed = false
        do { try await store.setup(onProgress: { await observation.accept(await store.allRecordings()) }) }
        catch { failed = true }
        XCTAssertTrue(failed, "An invalid head remains a real error, never an empty-success catalog")
        let visible = await observation.entries()
        XCTAssertEqual(visible.map(\.filename), ["Folder/One.mp3"], "A per-entity failure must not cancel resident B before progress delivery")
        XCTAssertNotNil(visible.first?.reference)
    }
    func testProgressiveCatalogCancellationStopsBeforeHeldHeadAndRetryLoadsIt() async throws {
        let (root, coordinator) = try await fixture()
        let a = try await coordinator.recording(at: "One.mp3")
        let head = root.appendingPathComponent(".docktape/records/" + a.state.id.uuidString.lowercased() + "/" + coordinator.writerID.uuidString.lowercased() + ".json")
        let started = expectation(description: "A owner head held for cancellation")
        let release = DispatchSemaphore(value: 0)
        let holder = Task {
            try await CoordinatedFileAccess().withWrite(at: head) { _ in
                started.fulfill()
                _ = release.wait(timeout: .now() + 8)
            }
        }
        await fulfillment(of: [started], timeout: 1)
        let store = RecordingStore(baseDirectory: root, shared: SharedRecordingMetadataAdapter(coordinator: coordinator))
        let observation = CatalogObservation()
        let loading = Task {
            var cancelled = false
            do { try await store.setup(onProgress: { await observation.accept(await store.allRecordings()) }) }
            catch { cancelled = error is CancellationError }
            await observation.finish()
            return cancelled
        }
        for _ in 0..<150 {
            if await observation.entries().contains(where: { $0.filename == "Folder/One.mp3" }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        loading.cancel()
        for _ in 0..<100 {
            if await observation.isFinished() { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let finishedWhileHeld = await observation.isFinished()
        let count = await observation.count()
        release.signal(); try await holder.value
        let cancelled = await loading.value
        XCTAssertTrue(finishedWhileHeld && cancelled, "Cancel must finish without waiting for the provider's held file")
        let callbacksAfterRelease = await observation.count()
        XCTAssertEqual(callbacksAfterRelease, count, "Cancelled progress cannot publish a late A entry")
        let retained = await store.allRecordings()
        XCTAssertEqual(retained.map(\.filename), ["Folder/One.mp3"])
        try await store.setup()
        let retried = await store.allRecordings()
        XCTAssertEqual(Set(retried.map(\.filename)), ["One.mp3", "Folder/One.mp3"])
    }

    func testProgressiveRetryNeverRevivesAnObservedDeletionAfterAnotherHeadFailed() async throws {
        let (root, coordinator) = try await fixture()
        let store = RecordingStore(baseDirectory: root, shared: SharedRecordingMetadataAdapter(coordinator: coordinator))
        try await store.setup()
        let a = try await coordinator.recording(at: "One.mp3")
        _ = try await coordinator.edit(.init(base: a, changes: [.delete]))
        let folders = try await coordinator.snapshots(kinds: [.folder])
        let folder = try XCTUnwrap(folders.first)
        let folderHead = root.appendingPathComponent(".docktape/folders/" + folder.state.id.uuidString.lowercased() + "/" + coordinator.writerID.uuidString.lowercased() + ".json")
        let folderBytes = try Data(contentsOf: folderHead)
        try Data("Malformed unrelated head".utf8).write(to: folderHead, options: .atomic)
        do { try await store.loadLibraryMeta(onProgress: {}); XCTFail("Fixture must retain the actual head error") }
        catch {}
        let observed = await store.allRecordings()
        XCTAssertFalse(observed.contains { $0.filename == "One.mp3" }, "The first partial refresh observed A's deletion")
        try folderBytes.write(to: folderHead, options: .atomic)
        let head = root.appendingPathComponent(".docktape/records/" + a.state.id.uuidString.lowercased() + "/" + coordinator.writerID.uuidString.lowercased() + ".json")
        let started = expectation(description: "Previously observed deleted A held for retry")
        let release = DispatchSemaphore(value: 0)
        let holder = Task {
            try await CoordinatedFileAccess().withWrite(at: head) { _ in
                started.fulfill()
                _ = release.wait(timeout: .now() + 8)
            }
        }
        await fulfillment(of: [started], timeout: 1)
        let observation = CatalogObservation()
        let retry = Task { try await store.loadLibraryMeta(onProgress: { await observation.accept(await store.allRecordings()) }) }
        for _ in 0..<150 {
            if await observation.count() > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let duringRetry = await observation.entries()
        release.signal(); try await holder.value; try await retry.value
        XCTAssertFalse(duringRetry.contains { $0.filename == "One.mp3" }, "A retry must retain the latest observed tombstone instead of seeding an older alive edit baseline")
        XCTAssertTrue(duringRetry.contains { $0.filename == "Folder/One.mp3" })
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("One.mp3")), Data("synthetic".utf8))
    }

    func testAcceptedDeletionHidesRetainedAudioUntilExplicitRestore() async throws {
        let (root, coordinator) = try await fixture()
        let store = RecordingStore(baseDirectory: root, shared: SharedRecordingMetadataAdapter(coordinator: coordinator))
        try await store.setup()
        try Data("untracked external audio".utf8).write(to: root.appendingPathComponent("Untracked.mp3"))
        let original = try await coordinator.recording(at: "One.mp3")
        let deleted = try await coordinator.edit(.init(base: original, changes: [.delete]))
        try await store.loadLibraryMeta()
        let pending = await store.allRecordings()
        XCTAssertFalse(pending.contains { $0.filename == "One.mp3" }, "A known deletion must be hidden while its single original is retained")
        XCTAssertTrue(pending.contains { $0.filename == "Folder/One.mp3" }, "Same basename is a different identity")
        XCTAssertTrue(pending.contains { $0.filename == "Untracked.mp3" }, "Unknown audio must not disappear merely because it has no reference")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("One.mp3").path))
        _ = try await coordinator.edit(.init(base: deleted, changes: [.restore]))
        try await store.loadLibraryMeta()
        let restored = await store.allRecordings()
        XCTAssertEqual(restored.first { $0.filename == "One.mp3" }?.reference?.entityID, original.state.id)
    }

    func testDeleteVersusEditRemainsVisibleForReview() async throws {
        let (root, coordinator) = try await fixture()
        let peer = SharedLibraryCoordinator(root: root, writerID: UUID())
        try await peer.requestEnrollment(requestID: UUID(), label: "Peer")
        try await coordinator.refresh(); try await peer.refresh(); try await coordinator.refresh()
        guard case .ready(let manifest) = try await LegacyLibraryBootstrap(root: root, writerID: coordinator.writerID).publishedManifest() else { return XCTFail("Ready fixture") }
        let original = try await coordinator.recording(at: "One.mp3")
        let repository = SharedLibraryRepository(root: root, writerID: peer.writerID, manifest: manifest)
        let offline = try await repository.load(entity: .init(id: original.state.id, kind: .recording))
        _ = try await coordinator.edit(.init(base: original, changes: [.delete]))
        _ = try await repository.commit(.init(base: offline, changes: [.assign(field: "metadata.mode", value: .text("\"Mee\""))]))
        let conflicted = try await coordinator.read(.init(id: original.state.id, kind: .recording))
        XCTAssertEqual(conflicted.state.lifecycle, .conflicted)
        let store = RecordingStore(baseDirectory: root, shared: SharedRecordingMetadataAdapter(coordinator: coordinator))
        try await store.setup()
        let recordings = await store.allRecordings()
        XCTAssertTrue(recordings.contains { $0.filename == "One.mp3" }, "A competing live edit must stay available for explicit review")
    }

    func testRealRecordingStoresRefreshAcceptedMetadataAndKeepNestedIdentities() async throws {
        let (root, coordinator) = try await fixture()
        let a = RecordingStore(baseDirectory: root, shared: SharedRecordingMetadataAdapter(coordinator: coordinator))
        let b = RecordingStore(baseDirectory: root, shared: SharedRecordingMetadataAdapter(coordinator: coordinator))
        try await a.setup(); try await b.setup()
        try await a.setMeta(mode: "Mee", deviceFilename: "first.hda", for: "One.mp3")
        try await b.setMeta(mode: "Pho", deviceFilename: "updated-second.hda", for: "Folder/One.mp3")
        try await a.loadLibraryMeta()
        let first = await a.mode(for: "One.mp3")
        let second = await a.mode(for: "Folder/One.mp3")
        XCTAssertEqual(first, "Mee"); XCTAssertEqual(second, "Pho")
        let filenames = await a.allImportedDeviceFilenames()
        XCTAssertEqual(filenames, ["first.hda", "updated-second.hda"])
    }
    func testIndependentMetadataFieldsMergeInsteadOfReplacingCachedEntry() async throws {
        let (root, coordinator) = try await fixture()
        let a = RecordingStore(baseDirectory: root, shared: SharedRecordingMetadataAdapter(coordinator: coordinator))
        let b = RecordingStore(baseDirectory: root, shared: SharedRecordingMetadataAdapter(coordinator: coordinator))
        try await a.setup(); try await b.setup()
        try await a.setMeta(mode: "Mee", deviceFilename: "first.hda", for: "One.mp3")
        try await b.setMeta(mode: "Rec", deviceFilename: "new.hda", for: "One.mp3")
        try await a.loadLibraryMeta()
        let mode = await a.mode(for: "One.mp3")
        let filenames = await a.allImportedDeviceFilenames()
        XCTAssertEqual(mode, "Mee")
        XCTAssertTrue(filenames.contains("new.hda"))
    }
    func testStaleSameFieldMetadataEditIsRejected() async throws {
        let (root, coordinator) = try await fixture()
        let a = RecordingStore(baseDirectory: root, shared: SharedRecordingMetadataAdapter(coordinator: coordinator))
        let b = RecordingStore(baseDirectory: root, shared: SharedRecordingMetadataAdapter(coordinator: coordinator))
        try await a.setup(); try await b.setup()
        try await a.setMeta(mode: "Mee", deviceFilename: "first.hda", for: "One.mp3")
        do {
            try await b.setMeta(mode: "Wip", deviceFilename: "first.hda", for: "One.mp3")
            XCTFail("A stale display must not consume another mode edit")
        } catch SharedLibraryCoordinatorError.staleReview {}
        try await b.loadLibraryMeta()
        let mode = await b.mode(for: "One.mp3")
        XCTAssertEqual(mode, "Mee")
    }
    func testRemovingModeIsExplicitAndDoesNotReappearFromLegacySeed() async throws {
        let (root, coordinator) = try await fixture()
        let store = RecordingStore(baseDirectory: root, shared: SharedRecordingMetadataAdapter(coordinator: coordinator))
        try await store.setup()
        try await store.setMeta(mode: "", deviceFilename: "first.hda", for: "One.mp3")
        try await store.loadLibraryMeta()
        let mode = await store.mode(for: "One.mp3")
        XCTAssertNil(mode)
    }
    func testAcceptedMetadataEditDoesNotReloadAnUnrelatedUnreadableRecording() async throws {
        let (root, coordinator) = try await fixture()
        let store = RecordingStore(baseDirectory: root, shared: SharedRecordingMetadataAdapter(coordinator: coordinator))
        try await store.setup()
        let other = try await coordinator.recording(at: "Folder/One.mp3")
        let file = root.appendingPathComponent(".docktape/records/\(other.state.id.uuidString.lowercased())/\(coordinator.writerID.uuidString.lowercased()).json")
        let original = try Data(contentsOf: file)
        defer { try? original.write(to: file, options: .atomic) }
        try Data("unreadable fixture".utf8).write(to: file, options: .atomic)
        do { try await store.setMeta(mode: "Mee", deviceFilename: "first.hda", for: "One.mp3") }
        catch { XCTFail("An accepted edit must not be reported failed by an unrelated reload: \(error)") }
        let cached = await store.mode(for: "One.mp3")
        XCTAssertEqual(cached, "Mee")
        let state = try await coordinator.recording(at: "One.mp3").state
        XCTAssertEqual(state.value(for: "metadata.mode"), .text("\"Mee\""))
    }

    func testCancellationAfterSemanticCommitReturnsTheAcceptedMetadataResult() async throws {
        let (root, original) = try await fixture()
        let coordinator = SharedLibraryCoordinator(root: root, writerID: original.writerID,
            afterCommit: { withUnsafeCurrentTask { $0?.cancel() } })
        let store = RecordingStore(baseDirectory: root, shared: SharedRecordingMetadataAdapter(coordinator: coordinator))
        try await store.setup()
        let work = Task { try await store.setMeta(mode: "Mee", deviceFilename: "first.hda", for: "One.mp3") }
        do { try await work.value }
        catch { XCTFail("A committed result cannot be reported as a rollback: \(error)") }
        let cached = await store.mode(for: "One.mp3")
        XCTAssertEqual(cached, "Mee")
        let state = try await original.recording(at: "One.mp3").state
        XCTAssertEqual(state.value(for: "metadata.mode"), .text("\"Mee\""))
    }

    private actor PausedLoad {
        var calls = 0
        var paused = false
        var continuation: CheckedContinuation<Void, Never>?
        func run() async {
            calls += 1
            if calls == 2 {
                paused = true
                await withCheckedContinuation { continuation = $0 }
            }
        }
        func release() { continuation?.resume(); continuation = nil }
        func isPaused() -> Bool { paused }
    }
    func testLoadStartedDuringMetadataEditCannotReplaceAcceptedResultOrBaseline() async throws {
        try await checkLoadDuringEdit(progressive: false)
    }
    func testProgressiveLoadStartedDuringMetadataEditCannotReplaceAcceptedResultOrBaseline() async throws {
        try await checkLoadDuringEdit(progressive: true)
    }
    private func checkLoadDuringEdit(progressive: Bool) async throws {
        let (root, original) = try await fixture()
        let witnesses = root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + "-edit-witnesses")
        roots.append(witnesses)
        let coordinator = SharedLibraryCoordinator(root: root, writerID: original.writerID, witnessDirectory: witnesses)
        let writable = try await coordinator.mayEdit()
        XCTAssertTrue(writable)
        guard case .ready(let manifest) = try await LegacyLibraryBootstrap(root: root, writerID: coordinator.writerID).publishedManifest() else {
            return XCTFail("Missing existing fixture manifest")
        }
        let pause = PausedLoad()
        let store = RecordingStore(baseDirectory: root, shared: SharedRecordingMetadataAdapter(coordinator: coordinator, beforeLoadReturn: { await pause.run() }))
        try await store.setup()
        let gate = witnesses.appendingPathComponent("Gates/" + manifest.libraryID.uuidString + "/" + coordinator.writerID.uuidString + ".lock")
        let started = expectation(description: "Local commit gate held while metadata reads remain available")
        let release = DispatchSemaphore(value: 0)
        let holder = Task {
            try await CoordinatedFileAccess().withWrite(at: gate) { _ in
                started.fulfill()
                _ = release.wait(timeout: .now() + 8)
            }
        }
        await fulfillment(of: [started], timeout: 1)
        let edit = Task { try await store.setMeta(mode: "Mee", deviceFilename: "first.hda", for: "One.mp3") }
        for _ in 0..<100 {
            if await store.mode(for: "One.mp3") == "Mee" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let began = await store.mode(for: "One.mp3") == "Mee"
        let load = Task {
            if progressive { try await store.loadLibraryMeta(onProgress: {}) }
            else { try await store.loadLibraryMeta() }
        }
        for _ in 0..<150 {
            if await pause.isPaused() { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let capturedBeforeCommit = await pause.isPaused()
        release.signal(); try await holder.value
        do { try await edit.value }
        catch { await pause.release(); _ = try? await load.value; throw error }
        let acceptedBeforeReturn = await store.mode(for: "One.mp3")
        await pause.release(); try await load.value
        XCTAssertTrue(began && capturedBeforeCommit, "The load must begin during an already-entered edit and capture state before commit")
        XCTAssertEqual(acceptedBeforeReturn, "Mee")
        let mode = await store.mode(for: "One.mp3")
        XCTAssertEqual(mode, "Mee", "A load that started during a pending edit must not overwrite the accepted result")
        try await store.setMeta(mode: "Wip", deviceFilename: "first.hda", for: "One.mp3")
        let latest = await store.mode(for: "One.mp3")
        XCTAssertEqual(latest, "Wip", "The accepted edit baseline must also survive the older captured result")
    }

    func testAnOlderMetadataLoadCannotOverwriteAnAcceptedEdit() async throws {
        try await checkOlderLoad(progressive: false)
    }
    func testAnOlderProgressiveMetadataLoadCannotOverwriteAnAcceptedEdit() async throws {
        try await checkOlderLoad(progressive: true)
    }
    private func checkOlderLoad(progressive: Bool) async throws {
        let (root, coordinator) = try await fixture()
        let pause = PausedLoad()
        let adapter = SharedRecordingMetadataAdapter(coordinator: coordinator, beforeLoadReturn: { await pause.run() })
        let store = RecordingStore(baseDirectory: root, shared: adapter)
        try await store.setup()
        let load = Task {
            if progressive { try await store.loadLibraryMeta(onProgress: {}) }
            else { try await store.loadLibraryMeta() }
        }
        let deadline = Date().addingTimeInterval(3)
        while !(await pause.isPaused()), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let reached = await pause.isPaused()
        XCTAssertTrue(reached)
        try await store.setMeta(mode: "Mee", deviceFilename: "first.hda", for: "One.mp3")
        await pause.release()
        try await load.value
        let mode = await store.mode(for: "One.mp3")
        XCTAssertEqual(mode, "Mee")
        try await store.setMeta(mode: "Wip", deviceFilename: "first.hda", for: "One.mp3")
        let latest = await store.mode(for: "One.mp3")
        XCTAssertEqual(latest, "Wip", "An old load must not replace the edit baseline either")
    }

}
