import Foundation
import FluidAudio

/// Speaker diarization engine backed by FluidAudio's offline pipeline
/// (pyannote Community-1 segmentation + WeSpeaker embedding + VBx clustering).
/// Runs fully locally on Apple Silicon via CoreML/ANE.
///
/// Configuration is tuned for HiDock's primary use case: table-top recorder
/// capturing 2-5 speakers in conversation (meetings, interviews, calls).
public final class FluidDiarizer: DiarizationEngine, @unchecked Sendable {
    /// Cache managers by numSpeakers to avoid recreating for repeated calls.
    /// Key: numSpeakers (0 = auto-detect)
    private var managers: [Int: OfflineDiarizerManager] = [:]

    public var modelIdentifier: String { "pyannote-community-1-vbx" }
    public var isReady: Bool { !managers.isEmpty }

    public init() {}

    /// Pre-load models with default configuration.
    public func prepare() async throws {
        _ = try await getManager(numSpeakers: nil)
    }

    public func diarize(
        audioURL: URL,
        numSpeakers: Int?,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> [SpeakerSegment] {
        let manager = try await getManager(numSpeakers: numSpeakers)

        onProgress?(0.1)

        let result = try await manager.process(audioURL)

        onProgress?(0.9)

        let segments = result.segments.map { seg in
            SpeakerSegment(
                speakerID: "Speaker \(seg.speakerId)",
                startTime: TimeInterval(seg.startTimeSeconds),
                endTime: TimeInterval(seg.endTimeSeconds)
            )
        }

        onProgress?(1.0)
        return segments
    }

    // MARK: - Private

    private func getManager(numSpeakers: Int?) async throws -> OfflineDiarizerManager {
        let key = numSpeakers ?? 0

        if let existing = managers[key] {
            return existing
        }

        var config = OfflineDiarizerConfig()

        // Lower clustering threshold for better speaker separation.
        // Default 0.6 is too liberal for mono table-top recordings where
        // speakers have similar distance/volume to the mic.
        config.clustering.threshold = 0.45

        // More conservative VBx — encourages distinct clusters
        config.clustering.warmStartFa = 0.05

        // Shorter minimum segment duration to catch brief interjections
        // like "yeah", "okay", "right" that help identify speaker turns
        config.embedding.minSegmentDurationSeconds = 0.5

        // Smaller gap merge to preserve speaker turn granularity
        config.postProcessing.minGapDurationSeconds = 0.05

        if let n = numSpeakers {
            config = config.withSpeakers(exactly: n)
        } else {
            // For auto-detect, hint that we expect at least 2 speakers.
            // HiDock is always recording a conversation.
            config = config.withSpeakers(min: 2)
        }

        let mgr = OfflineDiarizerManager(config: config)
        try await mgr.prepareModels()
        managers[key] = mgr
        return mgr
    }
}
