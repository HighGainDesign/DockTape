// © 2026 High Gain Design. All rights reserved.
import XCTest
@testable import HiDockKit

final class SharedUppercaseRecordingTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() { for root in roots { try? FileManager.default.removeItem(at: root) } }
    private let audio = Data("Owned uppercase synthetic audio".utf8)
    private func fixture(suffix: String = "MP3", in base: URL? = nil) async throws -> (URL, SharedLibraryCoordinator, RecordingStore) {
        let parent = (base ?? FileManager.default.temporaryDirectory).appendingPathComponent(UUID().uuidString)
        roots.append(parent)
        let root = parent.appendingPathComponent("library"), name = "Meeting." + suffix
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try audio.write(to: root.appendingPathComponent(name))
        let legacy = RecordingStore(baseDirectory: root); try await legacy.setup()
        try await legacy.setMeta(mode: "Mee", deviceFilename: "synthetic-device.hda", for: name)
        try await TranscriptStore(baseDirectory: root).save(Transcript(recordingFilename: name, transcriptionModel: "fixture",
            hasSpeakerLabels: false, segments: [.init(startTime: 0, endTime: 1, text: "Uppercase conversation")]), mp3Filename: name)
        try await SummaryStore(baseDirectory: root).save(Summary(recordingFilename: name, model: "fixture", provider: "fixture",
            templateUsed: "fixture", sections: [.init(heading: "Summary", content: "Uppercase summary")]), mp3Filename: name)
        let coordinator = SharedLibraryCoordinator(root: root, writerID: UUID(), witnessDirectory: parent.appendingPathComponent("local"), trash: { url in
            guard url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else { throw SharedLibraryOperationError.unsafePath }
            let recycled = parent.appendingPathComponent("recycled")
            try FileManager.default.createDirectory(at: recycled, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: recycled.appendingPathComponent(url.lastPathComponent))
        })
        _ = try await coordinator.enable()
        let store = RecordingStore(baseDirectory: root, shared: SharedRecordingMetadataAdapter(coordinator: coordinator))
        try await store.setup()
        return (root, coordinator, store)
    }
    func testBootstrapPreservesUppercaseIdentityAndSidecars() async throws {
        for suffix in ["MP3", "Mp3"] {
            let (root, coordinator, store) = try await fixture(suffix: suffix)
            let filename = "Meeting." + suffix
            let entries = await store.allRecordings()
            XCTAssertEqual(entries.map(\.filename), [filename])
            let reference = try XCTUnwrap(entries.first?.reference)
            let resolvedReference = try await coordinator.reference(to: filename)
            XCTAssertEqual(reference, resolvedReference)
            _ = try await coordinator.projectOutputs()
            let transcripts = TranscriptStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: coordinator))
            let summaries = SummaryStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: coordinator))
            let transcript = try await transcripts.loadTranscript(for: filename, reference: reference)
            let summary = try await summaries.loadSummary(for: filename, reference: reference)
            XCTAssertEqual(transcript?.plainText(), "Uppercase conversation")
            XCTAssertEqual(summary?.recordingFilename, filename)
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(filename)), audio)
            let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
            XCTAssertTrue(names.contains(filename)); XCTAssertFalse(names.contains("Meeting.mp3"))
            let settled = try await coordinator.projectOutputs()
            XCTAssertEqual(settled.written, 0)
        }
    }
    func testUppercaseRecordingMovesAndDeletesWithItsCompanions() async throws { try await lifecycle(in: nil) }
    private func lifecycle(in base: URL?) async throws {
        let (root, coordinator, store) = try await fixture(in: base)
        let reference = try await coordinator.reference(to: "Meeting.MP3")
        _ = try await coordinator.projectOutputs()
        let renamed = try await store.renameRecording(filename: "Meeting.MP3", to: "Renamed", reference: reference)
        XCTAssertEqual(renamed, "Renamed.MP3")
        try await store.createFolder(named: "Folder")
        let moved = try await store.moveRecording(filename: renamed, toFolder: "Folder", reference: reference)
        XCTAssertEqual(moved, "Folder/Renamed.MP3")
        _ = try await store.renameFolder(from: "Folder", to: "After")
        let selected = "After/Renamed.MP3"
        let resolved = try await coordinator.resolve(reference)
        XCTAssertEqual(resolved, selected)
        let transcript = try await TranscriptStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: coordinator))
            .loadTranscript(for: selected, reference: reference)
        XCTAssertEqual(transcript?.plainText(), "Uppercase conversation")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(selected)), audio)
        try await store.deleteRecordingAndSidecars(filename: selected, reference: reference)
        let replay = try await coordinator.resumeRecordingOperation(id: reference.entityID)
        XCTAssertEqual(replay.result, .complete)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(selected).path))
        XCTAssertEqual(try Data(contentsOf: root.deletingLastPathComponent().appendingPathComponent("recycled/Renamed.MP3")), audio)
    }
    func testInterruptedUppercaseRenameReplaysTheSameFiles() async throws { try await interrupted(in: nil) }
    private func interrupted(in base: URL?) async throws {
        struct Interrupted: Error {}
        let (root, coordinator, _) = try await fixture(in: base)
        let reference = try await coordinator.reference(to: "Meeting.MP3")
        _ = try await coordinator.projectOutputs()
        do {
            _ = try await coordinator.relocateRecording(filename: "Meeting.MP3", title: "Resumed", reference: reference,
                afterMutation: { _ in throw Interrupted() })
            XCTFail("Fixture must interrupt after the actual first file move")
        } catch is Interrupted { }
        let restarted = SharedLibraryCoordinator(root: root, writerID: coordinator.writerID,
            witnessDirectory: root.deletingLastPathComponent().appendingPathComponent("local"))
        let replay = try await restarted.resumeRecordingOperation(id: reference.entityID)
        XCTAssertEqual(replay.result, .complete)
        let resolved = try await restarted.resolve(reference)
        XCTAssertEqual(resolved, "Resumed.MP3")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Resumed.MP3")), audio)
        let summary = try await SummaryStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: restarted))
            .loadSummary(for: "Resumed.MP3", reference: reference)
        XCTAssertEqual(summary?.sections.first?.content, "Uppercase summary")
        let again = try await restarted.resumeRecordingOperation(id: reference.entityID)
        XCTAssertEqual(again.result, .complete)
    }
    func testUppercaseLifecycleAndReplayOnCaseSensitiveVolume() async throws {
        guard let configured = ProcessInfo.processInfo.environment["DOCKTAPE_CASE_SENSITIVE_TEST_ROOT"] else { throw XCTSkip("Requires owned case-sensitive APFS fixture") }
        let root = URL(fileURLWithPath: configured)
        XCTAssertEqual(try root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames, true)
        try await lifecycle(in: root); try await interrupted(in: root)
    }
}
