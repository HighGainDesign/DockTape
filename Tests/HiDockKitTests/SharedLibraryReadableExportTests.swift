// © 2026 High Gain Design. All rights reserved.
import XCTest
@testable import HiDockKit

final class SharedLibraryReadableExportTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() { for root in roots { try? FileManager.default.removeItem(at: root) } }
    func testResolvedSpeakerAndCheckboxEditsAppearInJSONAndReadableCompanions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        roots.append(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("synthetic".utf8).write(to: root.appendingPathComponent("Meeting.mp3"))
        let transcript = Transcript(recordingFilename: "Meeting.mp3", createdAt: Date(timeIntervalSince1970: 0),
            transcriptionModel: "fixture", hasSpeakerLabels: true,
            segments: [.init(startTime: 0, endTime: 1, text: "Literal conversation", speakerID: "s")])
        let item = Summary.Item(text: "Follow up")
        let summary = Summary(recordingFilename: "Meeting.mp3", createdAt: Date(timeIntervalSince1970: 0),
            model: "fixture", provider: "fixture", templateUsed: "meeting",
            sections: [.init(heading: "Tasks", content: "Summary content", items: [item])])
        try await TranscriptStore(baseDirectory: root).save(transcript, mp3Filename: "Meeting.mp3")
        try await SummaryStore(baseDirectory: root).save(summary, mp3Filename: "Meeting.mp3")
        let coordinator = SharedLibraryCoordinator(root: root, writerID: UUID())
        let manifest = try await coordinator.enable()
        let entity = try XCTUnwrap(manifest.references.first { $0.entity.kind == .recording }?.entity)
        let transcripts = TranscriptStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: coordinator))
        let summaries = SummaryStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: coordinator))
        _ = try await transcripts.loadTranscript(for: "Meeting.mp3")
        _ = try await summaries.loadSummary(for: "Meeting.mp3")
        try await transcripts.updateSpeakerNames(for: "Meeting.mp3", names: ["s": "Alice"])
        try await summaries.toggleItem(item.id, inSummaryFor: "Meeting.mp3")
        let view = try await coordinator.read(entity)
        let files = try SharedLibraryReadableExport.files(view: view, recordingPath: "Meeting.mp3")
        let md = String(decoding: try XCTUnwrap(files["Meeting.transcript.md"]), as: UTF8.self)
        let sm = String(decoding: try XCTUnwrap(files["Meeting.summary.md"]), as: UTF8.self)
        XCTAssertTrue(md.contains("Alice")); XCTAssertTrue(md.contains("Literal conversation"))
        XCTAssertTrue(md.contains("1970-01-01T00:00:00Z"))
        XCTAssertTrue(sm.contains("- [x] Follow up")); XCTAssertTrue(sm.contains("Summary content"))
        let decoded = try SharedContentCoding.decoder().decode(Transcript.self, from: XCTUnwrap(files["Meeting.transcript.json"]))
        XCTAssertEqual(decoded.speakerNames["s"], "Alice")
        let decodedSummary = try SharedContentCoding.decoder().decode(Summary.self, from: XCTUnwrap(files["Meeting.summary.json"]))
        XCTAssertTrue(decodedSummary.sections.first?.items?.first?.isCompleted == true)
        XCTAssertEqual(files, try SharedLibraryReadableExport.files(view: view, recordingPath: "Meeting.mp3"))
        XCTAssertTrue(String(decoding: try XCTUnwrap(files["Meeting.txt"]), as: UTF8.self).contains("Alice"))
        let marker = try SharedProjectionDocument.marker(in: XCTUnwrap(files["Meeting.transcript.json"]))
        XCTAssertEqual(marker?.libraryID, manifest.libraryID)
        XCTAssertEqual(marker?.entities, [entity.id])
    }
    func testExtremeFiniteTimestampDoesNotCrashReadableRendering() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        roots.append(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("synthetic".utf8).write(to: root.appendingPathComponent("Meeting.mp3"))
        let transcript = Transcript(recordingFilename: "Meeting.mp3", transcriptionModel: "fixture", hasSpeakerLabels: false,
            segments: [.init(startTime: 1e99, endTime: 1e99, text: "Large timestamp")])
        try await TranscriptStore(baseDirectory: root).save(transcript, mp3Filename: "Meeting.mp3")
        let coordinator = SharedLibraryCoordinator(root: root, writerID: UUID())
        let manifest = try await coordinator.enable()
        let entity = try XCTUnwrap(manifest.references.first { $0.entity.kind == .recording }?.entity)
        let view = try await coordinator.read(entity)
        XCTAssertThrowsError(try SharedLibraryReadableExport.files(view: view, recordingPath: "Meeting.mp3")) { error in
            XCTAssertEqual(error as? SharedSidecarError, .invalidContent)
        }
    }

}
