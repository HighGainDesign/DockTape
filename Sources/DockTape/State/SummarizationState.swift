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
    private let shared: SharedLibraryCoordinator?

    private var summarizationTask: Task<Void, Never>?
    /// Each queued item carries its own template so mixed-mode auto-summarize works.
    private var queue: [QueueEntry] = []

    var isSummarizing: Bool { summarizationTask != nil }

    private struct QueueEntry {
        let recording: RecordingMetadata
        let template: Template
        let customPrompt: String?
    }

    init(summaryStore: SummaryStore, shared: SharedLibraryCoordinator? = nil) {
        self.summaryStore = summaryStore
        self.shared = shared
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
        guard summarizationTask?.isCancelled != true else { return }
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

                var job: SharedLibraryJobToken?
                do {
                    try Task.checkCancellation()
                    let transcript: Transcript?
                    if let shared {
                        let view = try await shared.recording(at: rec.filename)
                        job = try await shared.pinJob(.init(id: view.state.id, kind: .recording), input: .transcript, output: .summary)
                        transcript = try await shared.transcriptForJob(job!, filename: rec.filename)
                    } else { transcript = await transcriptStore.transcript(for: rec.filename) }
                    guard let transcript else {
                        if let shared, let job { await shared.finishJob(job) }
                        onError("No transcript found for \(rec.displayTitle)")
                        queueIndex += 1
                        continue
                    }

                    try Task.checkCancellation()
                    let mode = job?.recordingMode ?? rec.mode
                    let isMemo = mode == "Wip"
                    let transcriptText = transcript.plainText(includeSpeakers: !isMemo)
                    let systemPrompt: String
                    if let customPrompt = entry.customPrompt {
                        systemPrompt = Template.buildCustomPrompt(customPrompt, mode: mode)
                    } else {
                        systemPrompt = entry.template.systemPrompt(forMode: mode)
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

                    try await summaryStore.save(summary, mp3Filename: rec.filename, job: job)
                    if let shared {
                        if let job { await shared.finishJob(job) }
                        do { _ = try await shared.projectOutputs() }
                        catch { onError("Summary saved, but library files need attention: \(error.localizedDescription)") }
                    }
                    hasSummary.insert(rec.filename)
                    queueIndex += 1
                } catch is CancellationError {
                    if let shared, let job { await shared.finishJob(job) }
                    resetState()
                    return
                } catch {
                    if let shared, let job { await shared.finishJob(job) }
                    if Task.isCancelled {
                        resetState()
                        return
                    }
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
        phase = "Cancelling summary..."
        // Keep ownership until the cancelled task exits, so it cannot clear a
        // subsequent queue or send a request after a delayed transcript read.
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
