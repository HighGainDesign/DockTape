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
    private func fixture(additionalAudio: [String] = []) async throws -> (URL, SharedLibraryCoordinator, RecordingStore, TranscriptStore) {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        roots.append(parent)
        let root = parent.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["Meeting.mp3"] + additionalAudio { try Data(("synthetic original " + name).utf8).write(to: root.appendingPathComponent(name)) }
        let coordinator = SharedLibraryCoordinator(root: root, writerID: UUID(), witnessDirectory: parent.appendingPathComponent("local"))
        _ = try await coordinator.enable()
        let records = RecordingStore(baseDirectory: root, shared: SharedRecordingMetadataAdapter(coordinator: coordinator))
        let transcripts = TranscriptStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: coordinator))
        return (root, coordinator, records, transcripts)
    }
    private actor RenameOnce {
        var ran = false
        let coordinator: SharedLibraryCoordinator
        let filename: String
        let reference: SharedRecordingReference
        init(coordinator: SharedLibraryCoordinator, filename: String, reference: SharedRecordingReference) {
            self.coordinator = coordinator; self.filename = filename; self.reference = reference
        }
        func run() async throws {
            guard !ran else { return }; ran = true
            let result = try await coordinator.relocateRecording(filename: filename, title: "Renamed while queued", reference: reference)
            guard result.result == .complete else { throw SharedLibraryOperationError.unfinishedOperation }
        }
    }
    func testBulkTranscriptionKeepsQueuedRecordingIdentityAfterRename() async throws {
        let (_, coordinator, records, transcripts) = try await fixture(additionalAudio: ["Later.mp3"])
        try await records.setup()
        let entries = await records.allRecordings()
        XCTAssertEqual(entries.count, 2)
        let second = entries[1], reference = try XCTUnwrap(entries[1].reference)
        let rename = RenameOnce(coordinator: coordinator, filename: second.filename, reference: reference)
        let pipeline = RecordingPipeline(recordingStore: records, transcriptStore: transcripts, shared: coordinator,
            transcriber: Engine(action: { try await rename.run() }))
        try await pipeline.setup()
        try await pipeline.transcribeAllLocal()
        let view = try await coordinator.read(.init(id: reference.entityID, kind: .recording))
        let transcript = try SharedSidecarAdapter.transcript(view, filename: "Renamed while queued.mp3")
        XCTAssertEqual(transcript?.plainText(), "Synthetic result", "Bulk transcription must resolve its captured ID after the other item renamed it")
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
