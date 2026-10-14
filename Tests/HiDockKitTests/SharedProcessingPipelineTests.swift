// © 2026 High Gain Design. All rights reserved.
import XCTest
@testable import HiDockKit

final class SharedProcessingPipelineTests: XCTestCase {
    struct Engine: TranscriptionEngine {
        var modelIdentifier: String { "synthetic engine" }
        var isReady: Bool { true }
        let action: @Sendable () async throws -> Void
        func transcribe(audioURL: URL, language: String?, onProgress: (@Sendable (Double) -> Void)?) async throws -> [Transcript.Segment] {
            try await action()
            return [.init(startTime: 0, endTime: 1, text: "Synthetic result")]
        }
    }
    private var roots: [URL] = []
    override func tearDown() { for root in roots { try? FileManager.default.removeItem(at: root) } }
    private func fixture() async throws -> (URL, SharedLibraryCoordinator, RecordingStore, TranscriptStore) {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        roots.append(parent)
        let root = parent.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("synthetic original".utf8).write(to: root.appendingPathComponent("Meeting.mp3"))
        let coordinator = SharedLibraryCoordinator(root: root, writerID: UUID(), witnessDirectory: parent.appendingPathComponent("local"))
        _ = try await coordinator.enable()
        let records = RecordingStore(baseDirectory: root, shared: SharedRecordingMetadataAdapter(coordinator: coordinator))
        let transcripts = TranscriptStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: coordinator))
        return (root, coordinator, records, transcripts)
    }
    func testActualSharedPipelinePublishesJSONMarkdownAndTextFromAcceptedGeneration() async throws {
        let (root, coordinator, records, transcripts) = try await fixture()
        let pipeline = RecordingPipeline(recordingStore: records, transcriptStore: transcripts, shared: coordinator, transcriber: Engine(action: {}))
        try await pipeline.setup()
        let result = try await pipeline.transcribeRecording(filename: "Meeting.mp3")
        XCTAssertEqual(result.segments.first?.text, "Synthetic result")
        for suffix in [".transcript.json", ".transcript.md", ".txt"] { XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Meeting" + suffix).path)) }
        let json = try Data(contentsOf: root.appendingPathComponent("Meeting.transcript.json"))
        XCTAssertNotNil(try SharedProjectionDocument.marker(in: json))
    }
    func testActualSharedPipelineCannotPublishAfterAudioChangesDuringInference() async throws {
        let (root, coordinator, records, transcripts) = try await fixture()
        let pipeline = RecordingPipeline(recordingStore: records, transcriptStore: transcripts, shared: coordinator,
            transcriber: Engine(action: { try Data("changed bytes".utf8).write(to: root.appendingPathComponent("Meeting.mp3"), options: .atomic) }))
        try await pipeline.setup()
        do { _ = try await pipeline.transcribeRecording(filename: "Meeting.mp3"); XCTFail("Changed physical input must invalidate result") }
        catch SharedLibraryCoordinatorError.staleJob {}
        let state = try await coordinator.recording(at: "Meeting.mp3")
        XCTAssertNil(state.state.currentDocument(for: .transcript))
    }
    func testActualSharedPipelineCannotPublishAfterDeletionDuringInference() async throws {
        let (root, coordinator, records, transcripts) = try await fixture()
        let entity = SharedEntityIdentity(id: try await coordinator.recording(at: "Meeting.mp3").state.id, kind: .recording)
        let pipeline = RecordingPipeline(recordingStore: records, transcriptStore: transcripts, shared: coordinator,
            transcriber: Engine(action: {
                _ = try await coordinator.edit(.init(base: try await coordinator.read(entity), changes: [.delete]))
            }))
        try await pipeline.setup()
        do { _ = try await pipeline.transcribeRecording(filename: "Meeting.mp3"); XCTFail("Deleted input must not be revived") }
        catch SharedLibraryCoordinatorError.staleJob {}
        let state = try await coordinator.read(entity)
        XCTAssertEqual(state.state.lifecycle, .deleted)
        XCTAssertNil(state.state.currentDocument(for: .transcript))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Meeting.mp3").path))
    }

}
