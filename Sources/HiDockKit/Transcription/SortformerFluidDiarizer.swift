// © 2026 High Gain Design. All rights reserved.

import Foundation
import FluidAudio

/// Speaker diarization engine backed by FluidAudio's SortFormer (NVIDIA).
/// End-to-end neural diarization with ~11% DER — significantly better than
/// the pyannote segmentation+embedding+clustering pipeline for mono recordings.
///
/// Uses `.highContextV2_1` config for best accuracy on offline recordings.
/// Runs fully locally on Apple Silicon via CoreML.
public final class SortformerFluidDiarizer: DiarizationEngine, @unchecked Sendable {
    private var diarizer: SortformerDiarizer?
    private let sortformerConfig: SortformerConfig

    public var modelIdentifier: String { "sortformer-highcontext-v2.1" }
    public var isReady: Bool { diarizer != nil }

    /// - Parameter config: SortFormer configuration preset. Default `.highContextV2_1` for best accuracy.
    public init(config: SortformerConfig = .highContextV2_1) {
        self.sortformerConfig = config
    }

    /// Download models from HuggingFace (cached after first run) and initialize.
    public func prepare() async throws {
        let d = SortformerDiarizer(config: sortformerConfig)
        let models = try await SortformerModels.loadFromHuggingFace(config: sortformerConfig)
        d.initialize(models: models)
        self.diarizer = d
    }

    public func diarize(
        audioURL: URL,
        numSpeakers: Int?,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> [SpeakerSegment] {
        if diarizer == nil {
            try await prepare()
        }
        guard let diarizer else {
            throw HiDockError.conversionFailed("Failed to initialize diarization engine after prepare()")
        }

        onProgress?(0.05)

        // processComplete is synchronous and CPU-intensive — run off the main actor
        let timeline = try await Task.detached { [diarizer] in
            try diarizer.processComplete(audioFileURL: audioURL) { processed, total, _ in
                let progress = Double(processed) / Double(max(total, 1))
                onProgress?(0.05 + progress * 0.9)
            }
        }.value

        onProgress?(0.95)

        // Collect finalized segments from all speakers
        var segments: [SpeakerSegment] = []
        for (_, speaker) in timeline.speakers {
            for seg in speaker.finalizedSegments {
                segments.append(SpeakerSegment(
                    speakerID: seg.speakerLabel,
                    startTime: TimeInterval(seg.startTime),
                    endTime: TimeInterval(seg.endTime)
                ))
            }
        }

        // Sort by start time for consistent merge behavior
        segments.sort { $0.startTime < $1.startTime }

        onProgress?(1.0)
        return segments
    }
}
