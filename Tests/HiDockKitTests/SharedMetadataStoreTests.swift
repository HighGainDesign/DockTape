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
    func testAnOlderMetadataLoadCannotOverwriteAnAcceptedEdit() async throws {
        let (root, coordinator) = try await fixture()
        let pause = PausedLoad()
        let adapter = SharedRecordingMetadataAdapter(coordinator: coordinator, beforeLoadReturn: { await pause.run() })
        let store = RecordingStore(baseDirectory: root, shared: adapter)
        try await store.setup()
        let load = Task { try await store.loadLibraryMeta() }
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
