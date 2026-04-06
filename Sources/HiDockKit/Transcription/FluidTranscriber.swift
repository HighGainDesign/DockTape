import Foundation
import FluidAudio

/// Transcription engine backed by FluidAudio's Parakeet ASR (CoreML/ANE).
/// Runs fully locally on Apple Silicon.
public final class FluidTranscriber: TranscriptionEngine, @unchecked Sendable {
    private var asrManager: AsrManager?
    private let modelVersion: AsrModelVersion

    public var modelIdentifier: String { "parakeet-tdt-\(modelVersion)" }
    public var isReady: Bool { asrManager != nil }

    /// - Parameter modelVersion: `.v3` for multilingual (25 languages), `.v2` for English-only.
    public init(modelVersion: AsrModelVersion = .v3) {
        self.modelVersion = modelVersion
    }

    /// Load models (downloads from HuggingFace on first run, then cached).
    public func prepare() async throws {
        let models = try await AsrModels.downloadAndLoad(version: modelVersion)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.asrManager = manager
    }

    public func transcribe(
        audioURL: URL,
        language: String?,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> [Transcript.Segment] {
        guard let manager = asrManager else {
            try await prepare()
            return try await transcribe(audioURL: audioURL, language: language, onProgress: onProgress)
        }

        onProgress?(0.1)

        let result = try await manager.transcribe(audioURL, source: .system)

        onProgress?(0.9)

        // Convert FluidAudio ASR result to our Transcript.Segment format
        var segments: [Transcript.Segment] = []

        if let timings = result.tokenTimings, !timings.isEmpty {
            // Build word-level segments from subword tokens.
            // SentencePiece convention: space-prefixed tokens mark word starts.
            // We produce short segments (per-sentence or ~5s max) to give the
            // diarization merge fine-grained boundaries for speaker assignment.
            var currentText = ""
            var currentStart: TimeInterval = 0
            var currentEnd: TimeInterval = 0

            for timing in timings {
                guard !timing.token.isEmpty else { continue }

                if currentText.isEmpty {
                    currentStart = timing.startTime
                    currentText = timing.token.trimmingCharacters(in: .whitespaces)
                } else {
                    currentText += timing.token
                }
                currentEnd = timing.endTime

                // Split at sentence boundaries or every ~5 seconds (shorter for
                // better diarization alignment — speaker turns happen frequently)
                let trimmed = timing.token.trimmingCharacters(in: .whitespaces)
                let isPunctuation = trimmed.last.map { ".!?,".contains($0) } ?? false
                let isLongChunk = (currentEnd - currentStart) > 5.0

                if isPunctuation || isLongChunk {
                    segments.append(Transcript.Segment(
                        startTime: currentStart,
                        endTime: currentEnd,
                        text: currentText.trimmingCharacters(in: .whitespaces),
                        confidence: result.confidence
                    ))
                    currentText = ""
                }
            }

            // Flush remaining
            if !currentText.isEmpty {
                segments.append(Transcript.Segment(
                    startTime: currentStart,
                    endTime: currentEnd,
                    text: currentText.trimmingCharacters(in: .whitespaces),
                    confidence: result.confidence
                ))
            }
        } else {
            // No token-level timestamps — use the full result as one segment
            segments.append(Transcript.Segment(
                startTime: 0,
                endTime: result.duration,
                text: result.text,
                confidence: result.confidence
            ))
        }

        onProgress?(1.0)
        return segments
    }
}
