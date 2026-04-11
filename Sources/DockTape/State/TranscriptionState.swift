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

    let transcriptStore: TranscriptStore

    init(transcriptStore: TranscriptStore) {
        self.transcriptStore = transcriptStore
    }

    var isTranscribing: Bool { transcribingFile != nil }

    func transcribe(
        recordings: [RecordingMetadata],
        baseDirectory: URL,
        onStatusMessage: @escaping (String) -> Void,
        onError: @escaping (String) -> Void,
        onComplete: @escaping () async -> Void
    ) async {
        let existingFilenames = Set(queue.map(\.filename))
        let newRecs = recordings.filter { !existingFilenames.contains($0.filename) }
        queue.append(contentsOf: newRecs)

        for rec in newRecs {
            statuses[rec.filename] = .inProgress
        }

        guard transcriptionTask == nil else { return }
        startTime = Date()

        let task = Task {
            do {
                if pipeline == nil {
                    phase = "Loading models (first time takes ~1 min)..."
                    onStatusMessage(phase)
                    pipeline = RecordingPipeline(baseDirectory: baseDirectory)
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

                    try? await transcriptStore.delete(for: rec.filename)
                    let transcript = try await pipeline!.transcribeRecording(filename: rec.filename)
                    try Task.checkCancellation()

                    try? await transcriptStore.save(transcript, mp3Filename: rec.filename)
                    statuses[rec.filename] = .done
                    queueIndex += 1
                }

                let count = queue.count
                onStatusMessage(count == 1 ? "Transcription complete" : "Transcribed \(count) recordings")
                resetState()
                await onComplete()
            } catch is CancellationError {
                if let file = transcribingFile {
                    statuses[file] = TranscriptStatus.none
                }
                onStatusMessage("Transcription cancelled")
                resetState()
            } catch {
                if let file = transcribingFile {
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
        transcriptionTask = nil
        if let file = transcribingFile {
            statuses[file] = TranscriptStatus.none
        }
        for rec in queue.dropFirst(queueIndex + 1) {
            statuses[rec.filename] = TranscriptStatus.none
        }
        resetState()
    }

    private func resetState() {
        transcribingFile = nil
        phase = ""
        queue = []
        queueIndex = 0
        startTime = nil
        transcriptionTask = nil
    }
}
