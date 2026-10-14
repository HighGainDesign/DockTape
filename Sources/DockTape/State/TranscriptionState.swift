// © 2026 High Gain Design. All rights reserved.

import SwiftUI
import HiDockKit

/// Isolated transcription state.
@Observable
@MainActor
final class TranscriptionState {
    var transcribingFile: String?
    var phase: String = ""
    var queue: [RecordingMetadata] = []
    var queueIndex: Int = 0
    var startTime: Date?
    var statuses: [String: TranscriptStatus] = [:]

    private var transcriptionTask: Task<Void, Never>?
    private var pipeline: RecordingPipeline?
    private var previousStatuses: [String: TranscriptStatus] = [:]

    let transcriptStore: TranscriptStore
    private let recordingStore: RecordingStore?
    private let shared: SharedLibraryCoordinator?

    init(transcriptStore: TranscriptStore, recordingStore: RecordingStore? = nil, shared: SharedLibraryCoordinator? = nil) {
        self.transcriptStore = transcriptStore
        self.recordingStore = recordingStore
        self.shared = shared
    }

    var isTranscribing: Bool { transcriptionTask != nil }

    func transcribe(
        recordings: [RecordingMetadata],
        baseDirectory: URL,
        onStatusMessage: @escaping (String) -> Void,
        onError: @escaping (String) -> Void,
        onComplete: @escaping () async -> Void
    ) async {
        guard transcriptionTask?.isCancelled != true else { return }
        let existingFilenames = Set(queue.map(\.filename))
        let newRecs = recordings.filter { !existingFilenames.contains($0.filename) }
        queue.append(contentsOf: newRecs)

        for rec in newRecs {
            previousStatuses[rec.filename] = statuses[rec.filename] ?? TranscriptStatus.none
            statuses[rec.filename] = .inProgress
        }

        guard transcriptionTask == nil else { return }
        startTime = Date()

        let task = Task {
            do {
                if pipeline == nil {
                    phase = "Loading models (first time takes ~1 min)..."
                    onStatusMessage(phase)
                    pipeline = RecordingPipeline(recordingStore: recordingStore ?? RecordingStore(baseDirectory: baseDirectory), transcriptStore: transcriptStore, shared: shared)
                    try await pipeline!.setup()
                }

                while queueIndex < queue.count {
                    try Task.checkCancellation()

                    let index = queueIndex
                    let rec = queue[index]
                    let total = queue.count

                    transcribingFile = rec.filename
                    statuses[rec.filename] = .inProgress
                    startTime = Date()
                    let progress = total > 1 ? " (\(index + 1)/\(total))" : ""
                    phase = "Transcribing\(progress)..."
                    onStatusMessage("Transcribing \(rec.filename)\(progress)...")

                    let transcript = try await pipeline!.transcribeRecording(filename: rec.filename)
                    try Task.checkCancellation()

                    if shared == nil { try await transcriptStore.save(transcript, mp3Filename: rec.filename) }
                    if let message = await pipeline!.projectionError { onError("Transcript saved, but library files need attention: \(message)") }
                    statuses[rec.filename] = .done
                    queueIndex += 1
                }

                let count = queue.count
                onStatusMessage(count == 1 ? "Transcription complete" : "Transcribed \(count) recordings")
                resetState()
                await onComplete()
            } catch is CancellationError {
                restorePendingStatuses()
                onStatusMessage("Transcription cancelled")
                resetState()
            } catch {
                restorePendingStatuses()
                if let file = transcribingFile, previousStatuses[file] != .done {
                    statuses[file] = .failed
                }
                onError("Transcription failed: \(error.localizedDescription)")
                onStatusMessage("Transcription failed")
                resetState()
            }
        }
        transcriptionTask = task
    }

    func cancel() {
        transcriptionTask?.cancel()
        phase = "Cancelling transcription..."
        // The running task owns cleanup. Starting another task before it exits
        // would let the cancelled task clear the new queue and progress.
    }

    private func restorePendingStatuses() {
        for rec in queue where statuses[rec.filename] == .inProgress {
            statuses[rec.filename] = previousStatuses[rec.filename] ?? TranscriptStatus.none
        }
    }

    private func resetState() {
        transcribingFile = nil
        phase = ""
        queue = []
        previousStatuses = [:]
        queueIndex = 0
        startTime = nil
        transcriptionTask = nil
    }
}
