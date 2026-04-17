// © 2026 High Gain Design. All rights reserved.

import SwiftUI
import HiDockKit

/// Manages AI summarization queue and progress.
@Observable
@MainActor
final class SummarizationState {
    var summarizingFile: String?
    var phase: String = ""
    var queueCount: Int = 0
    var queueIndex: Int = 0
    /// Tracks which recordings have summaries (for synchronous UI checks).
    var hasSummary: Set<String> = []

    let summaryStore: SummaryStore

    private var summarizationTask: Task<Void, Never>?
    /// Each queued item carries its own template so mixed-mode auto-summarize works.
    private var queue: [QueueEntry] = []

    var isSummarizing: Bool { summarizingFile != nil }

    private struct QueueEntry {
        let recording: RecordingMetadata
        let template: Template
        let customPrompt: String?
    }

    init(summaryStore: SummaryStore) {
        self.summaryStore = summaryStore
    }

    func summarize(
        recordings: [RecordingMetadata],
        template: Template,
        customPrompt: String?,
        provider: any LLMProvider,
        model: String,
        transcriptStore: TranscriptStore,
        onError: @MainActor @Sendable @escaping (String) -> Void,
        onComplete: @MainActor @Sendable @escaping () -> Void
    ) {
        let existing = Set(queue.map(\.recording.filename))
        let newEntries = recordings
            .filter { !existing.contains($0.filename) }
            .map { QueueEntry(recording: $0, template: template, customPrompt: customPrompt) }
        queue.append(contentsOf: newEntries)
        queueCount = queue.count

        guard summarizationTask == nil else { return }

        summarizationTask = Task {
            while queueIndex < queue.count {
                let entry = queue[queueIndex]
                let rec = entry.recording
                summarizingFile = rec.filename
                phase = "Summarizing with \(model)..."

                do {
                    guard let transcript = await transcriptStore.transcript(for: rec.filename) else {
                        onError("No transcript found for \(rec.displayTitle)")
                        queueIndex += 1
                        continue
                    }

                    let isMemo = rec.mode == "Wip"
                    let transcriptText = transcript.plainText(includeSpeakers: !isMemo)
                    let systemPrompt: String
                    if let customPrompt = entry.customPrompt {
                        systemPrompt = Template.buildCustomPrompt(customPrompt, mode: rec.mode)
                    } else {
                        systemPrompt = entry.template.systemPrompt(forMode: rec.mode)
                    }

                    let responseText = try await provider.summarize(
                        transcript: transcriptText,
                        systemPrompt: systemPrompt,
                        model: model
                    )

                    try Task.checkCancellation()

                    let sections = Template.parseSections(from: responseText)
                    let summary = Summary(
                        recordingFilename: rec.filename,
                        model: model,
                        provider: provider.name.lowercased(),
                        templateUsed: entry.template.id,
                        customPrompt: entry.customPrompt,
                        sections: sections
                    )

                    try await summaryStore.save(summary, mp3Filename: rec.filename)
                    hasSummary.insert(rec.filename)
                    queueIndex += 1
                } catch is CancellationError {
                    resetState()
                    return
                } catch {
                    onError("Summarization failed: \(error.localizedDescription)")
                    queueIndex += 1
                }
            }

            resetState()
            onComplete()
        }
    }

    func cancel() {
        summarizationTask?.cancel()
        resetState()
    }

    private func resetState() {
        summarizingFile = nil
        phase = ""
        queue = []
        queueCount = 0
        queueIndex = 0
        summarizationTask = nil
    }
}
