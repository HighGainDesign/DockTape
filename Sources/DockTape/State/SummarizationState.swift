import SwiftUI
import HiDockKit

/// Manages AI summarization queue and progress.
@Observable
@MainActor
final class SummarizationState {
    var summarizingFile: String?
    var phase: String = ""
    var queue: [RecordingMetadata] = []
    var queueIndex: Int = 0

    let summaryStore: SummaryStore

    private var summarizationTask: Task<Void, Never>?

    var isSummarizing: Bool { summarizingFile != nil }

    init(summaryStore: SummaryStore) {
        self.summaryStore = summaryStore
    }

    func summarize(
        recordings: [RecordingMetadata],
        template: SummaryTemplate,
        customPrompt: String?,
        provider: any LLMProvider,
        model: String,
        transcriptStore: TranscriptStore,
        onError: @escaping (String) -> Void,
        onComplete: @escaping () -> Void
    ) {
        let newRecs = recordings.filter { rec in !queue.contains(where: { $0.filename == rec.filename }) }
        queue.append(contentsOf: newRecs)

        guard summarizationTask == nil else { return }

        summarizationTask = Task {
            while queueIndex < queue.count {
                let rec = queue[queueIndex]
                summarizingFile = rec.filename
                phase = "Summarizing with \(provider.name)..."

                do {
                    guard let transcript = await transcriptStore.transcript(for: rec.filename) else {
                        onError("No transcript found for \(rec.displayTitle)")
                        queueIndex += 1
                        continue
                    }

                    let transcriptText = transcript.plainText(includeSpeakers: true)
                    let effectiveTemplate = template == .custom
                        ? template
                        : SummaryTemplate.forMode(rec.mode)
                    let systemPrompt = effectiveTemplate == .custom
                        ? SummaryTemplate.buildCustomPrompt(customPrompt ?? "")
                        : effectiveTemplate.systemPrompt

                    let responseText = try await provider.summarize(
                        transcript: transcriptText,
                        systemPrompt: systemPrompt,
                        model: model
                    )

                    try Task.checkCancellation()

                    let sections = try SummaryTemplate.parseSections(from: responseText)
                    let summary = Summary(
                        recordingFilename: rec.filename,
                        model: model,
                        provider: provider.name.lowercased(),
                        templateUsed: effectiveTemplate.rawValue,
                        customPrompt: effectiveTemplate == .custom ? customPrompt : nil,
                        sections: sections
                    )

                    try await summaryStore.save(summary, mp3Filename: rec.filename)
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
        queueIndex = 0
        summarizationTask = nil
    }
}
