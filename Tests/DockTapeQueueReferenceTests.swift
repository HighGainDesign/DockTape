// © 2026 High Gain Design. All rights reserved.
import AppKit
import HiDockKit

@main
struct DockTapeQueueReferenceTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func expect(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    actor Provider: LLMProvider {
        nonisolated let name = "Fixture", defaultModel = "fixture", availableModels = ["fixture"]
        var transcripts: [String] = []
        let records: RecordingStore
        init(records: RecordingStore) { self.records = records }
        func verifyKey() async throws {}
        func summarize(transcript: String, systemPrompt: String, model: String) async throws -> String {
            transcripts.append(transcript)
            if transcripts.count == 1 { _ = try await records.renameRecording(filename: "Second.mp3", to: "Moved") }
            return "Synthetic result"
        }
    }
    actor EngineAction {
        var count = 0
        let records: RecordingStore
        init(records: RecordingStore) { self.records = records }
        func run() async throws {
            count += 1
            if count == 1 { _ = try await records.renameRecording(filename: "Moved.mp3", to: "Again") }
        }
    }
    struct Engine: TranscriptionEngine {
        let action: EngineAction
        var modelIdentifier: String { "fixture" }
        var isReady: Bool { true }
        func transcribe(audioURL: URL, language: String?, onProgress: (@Sendable (Double) -> Void)?) async throws -> [Transcript.Segment] {
            try await action.run()
            return [.init(startTime: 0, endTime: 1, text: "Synthetic transcript")]
        }
    }
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("DockTapeQueue-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["First", "Second"] {
            try Data("synthetic audio".utf8).write(to: root.appendingPathComponent(name + ".mp3"))
            try await TranscriptStore(baseDirectory: root).save(Transcript(recordingFilename: name + ".mp3", transcriptionModel: "fixture", hasSpeakerLabels: false,
                segments: [.init(startTime: 0, endTime: 1, text: name + " conversation")]), mp3Filename: name + ".mp3")
        }
        let shared = SharedLibraryCoordinator(root: root, writerID: UUID(), witnessDirectory: parent.appendingPathComponent("local"))
        _ = try await shared.enable(); _ = try await shared.projectOutputs()
        let records = RecordingStore(baseDirectory: root, shared: SharedRecordingMetadataAdapter(coordinator: shared))
        try await records.setup()
        let queue = SummarizationState(summaryStore: SummaryStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: shared)), shared: shared)
        let provider = Provider(records: records)
        var failures: [String] = []
        let selected = await records.allRecordings().sorted { $0.filename < $1.filename }
        try expect(selected.allSatisfy { $0.reference != nil }, "Displayed shared metadata must carry recording identities")
        queue.summarize(recordings: selected, template: TemplateStore.builtInDefaults[0], customPrompt: nil, provider: provider, model: "fixture",
            transcriptStore: TranscriptStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: shared)), onError: { failures.append($0) }, onComplete: {})
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while queue.isSummarizing {
            guard ContinuousClock.now < deadline else { throw Failure(description: "Queue timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
        try expect(await provider.transcripts.count == 2, "Queued item must follow its ID after a completed rename")
        try expect(failures.isEmpty, "Queued rename should not fail: " + failures.joined(separator: "; "))
        try expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Moved.summary.json").path), "Second result must use current path")
        try expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Second.summary.json").path), "Do not recreate stale filename")
        try await records.loadLibraryMeta()
        let next = await records.allRecordings().sorted { $0.filename < $1.filename }
        let engine = EngineAction(records: records)
        let transcription = TranscriptionState(transcriptStore: TranscriptStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: shared)),
            recordingStore: records, shared: shared, preparedEngine: Engine(action: engine))
        await transcription.transcribe(recordings: next, baseDirectory: root, onStatusMessage: { _ in }, onError: { failures.append($0) }, onComplete: {})
        let transcriptionDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while transcription.isTranscribing {
            guard ContinuousClock.now < transcriptionDeadline else { throw Failure(description: "Transcription queue timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
        try expect(await engine.count == 2 && failures.isEmpty, "Transcription queue must follow published identity paths")
        try expect(transcription.statuses["Again.mp3"] == .done && transcription.statuses["Moved.mp3"] == nil, "Status keys must follow the successful path")
        try expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Again.transcript.json").path), "Transcription must publish at resolved path")
        print("Actual queue references passed: rename while prior item runs, current-path output and no stale-path recreation.")
    }
}
