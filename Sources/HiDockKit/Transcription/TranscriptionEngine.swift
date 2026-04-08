import Foundation

/// Protocol for transcription backends.
/// The default implementation uses Parakeet ASR via FluidAudio.
public protocol TranscriptionEngine: Sendable {
    /// Transcribe an audio file and return timestamped segments.
    /// - Parameters:
    ///   - audioURL: Path to the audio file (MP3, WAV, etc.)
    ///   - language: Optional language hint (e.g., "en"). nil = auto-detect.
    ///   - onProgress: Progress callback (0.0–1.0).
    func transcribe(
        audioURL: URL,
        language: String?,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> [Transcript.Segment]

    /// The model identifier (e.g., "parakeet-tdt-1.0").
    var modelIdentifier: String { get }

    /// Whether the engine is ready (model loaded, etc.).
    var isReady: Bool { get }
}

/// Protocol for speaker diarization backends.
/// Implementations assign speaker IDs to time regions of audio.
public protocol DiarizationEngine: Sendable {
    /// Perform speaker diarization on an audio file.
    /// Returns time-stamped speaker segments.
    func diarize(
        audioURL: URL,
        numSpeakers: Int?,  // nil = auto-detect
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> [SpeakerSegment]

    /// The model identifier.
    var modelIdentifier: String { get }

    var isReady: Bool { get }
}

/// A time region assigned to a speaker.
public struct SpeakerSegment: Sendable {
    public let speakerID: String      // "Speaker 1", "Speaker 2", etc.
    public let startTime: TimeInterval
    public let endTime: TimeInterval

    public init(speakerID: String, startTime: TimeInterval, endTime: TimeInterval) {
        self.speakerID = speakerID
        self.startTime = startTime
        self.endTime = endTime
    }
}

/// Combines transcription and diarization into speaker-labeled transcripts.
public enum TranscriptionPipeline {

    /// Run transcription, then optionally merge with diarization results.
    public static func transcribe(
        audioURL: URL,
        recordingFilename: String,
        transcriber: any TranscriptionEngine,
        diarizer: (any DiarizationEngine)? = nil,
        language: String? = nil,
        numSpeakers: Int? = nil,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Transcript {
        // Step 1: Transcribe (0–70% of progress)
        let segments = try await transcriber.transcribe(
            audioURL: audioURL,
            language: language,
            onProgress: { p in onProgress?(p * 0.7) }
        )

        // Step 2: Diarize if engine provided (70–100%)
        let finalSegments: [Transcript.Segment]
        let hasSpeakers: Bool

        if let diarizer {
            let speakerSegments = try await diarizer.diarize(
                audioURL: audioURL,
                numSpeakers: numSpeakers,
                onProgress: { p in onProgress?(0.7 + p * 0.3) }
            )
            finalSegments = mergeSpeakersAtWordLevel(
                transcription: segments,
                diarization: speakerSegments
            )
            hasSpeakers = true
        } else {
            finalSegments = segments
            hasSpeakers = false
        }

        onProgress?(1.0)

        return Transcript(
            recordingFilename: recordingFilename,
            transcriptionModel: transcriber.modelIdentifier,
            hasSpeakerLabels: hasSpeakers,
            segments: finalSegments,
            language: language
        )
    }

    /// Assign speakers at the word/token level, then re-group into speaker turns.
    ///
    /// Strategy:
    /// 1. Each ASR segment gets a speaker based on which diarization segment
    ///    covers its midpoint (or nearest if no exact match).
    /// 2. Consecutive segments with the same speaker are merged into turns.
    /// 3. Turns are split at sentence boundaries for readability.
    static func mergeSpeakersAtWordLevel(
        transcription: [Transcript.Segment],
        diarization: [SpeakerSegment]
    ) -> [Transcript.Segment] {
        guard !diarization.isEmpty else { return transcription }

        // Sort diarization by start time for binary search
        let sortedDiar = diarization.sorted { $0.startTime < $1.startTime }

        // Step 1: Assign each ASR segment a speaker
        var labeled: [(segment: Transcript.Segment, speaker: String)] = []
        for seg in transcription {
            let midpoint = (seg.startTime + seg.endTime) / 2
            let speaker = findSpeaker(at: midpoint, in: sortedDiar)
            labeled.append((seg, speaker))
        }

        // Step 2: Group consecutive same-speaker segments into turns,
        // then split at sentence boundaries for readability
        var result: [Transcript.Segment] = []
        var turnText = ""
        var turnStart: TimeInterval = 0
        var turnEnd: TimeInterval = 0
        var turnSpeaker = ""
        var turnConfidence: Float = 0
        var turnConfCount = 0

        for (seg, speaker) in labeled {
            if speaker != turnSpeaker && !turnText.isEmpty {
                // Speaker changed — flush current turn
                result.append(contentsOf: splitTurnIntoSentences(
                    text: turnText, start: turnStart, end: turnEnd,
                    speaker: turnSpeaker,
                    confidence: turnConfCount > 0 ? turnConfidence / Float(turnConfCount) : nil
                ))
                turnText = ""
            }

            if turnText.isEmpty {
                turnStart = seg.startTime
                turnSpeaker = speaker
                turnConfidence = 0
                turnConfCount = 0
            }

            // Append text using SentencePiece convention
            if turnText.isEmpty {
                turnText = seg.text
            } else {
                turnText += " " + seg.text
            }
            turnEnd = seg.endTime
            if let c = seg.confidence {
                turnConfidence += c
                turnConfCount += 1
            }
        }

        // Flush remaining
        if !turnText.isEmpty {
            result.append(contentsOf: splitTurnIntoSentences(
                text: turnText, start: turnStart, end: turnEnd,
                speaker: turnSpeaker,
                confidence: turnConfCount > 0 ? turnConfidence / Float(turnConfCount) : nil
            ))
        }

        return result
    }

    /// Split a speaker turn at sentence boundaries for readability.
    /// Each resulting segment keeps the same speaker but has its own time range.
    private static func splitTurnIntoSentences(
        text: String, start: TimeInterval, end: TimeInterval,
        speaker: String, confidence: Float?
    ) -> [Transcript.Segment] {
        let duration = end - start
        guard duration > 0, !text.isEmpty else { return [] }

        // Split at sentence boundaries (. ! ?)
        var sentences: [String] = []
        var current = ""
        for char in text {
            current.append(char)
            if ".!?".contains(char) {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    sentences.append(trimmed)
                }
                current = ""
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty {
            sentences.append(current.trimmingCharacters(in: .whitespaces))
        }

        guard sentences.count > 1 else {
            return [Transcript.Segment(
                startTime: start, endTime: end,
                text: text.trimmingCharacters(in: .whitespaces),
                speakerID: speaker, confidence: confidence
            )]
        }

        // Distribute time proportionally by character count
        let totalChars = sentences.reduce(0) { $0 + $1.count }
        var currentTime = start
        return sentences.map { sentence in
            let frac = Double(sentence.count) / Double(max(totalChars, 1))
            let segEnd = min(currentTime + frac * duration, end)
            let seg = Transcript.Segment(
                startTime: currentTime, endTime: segEnd,
                text: sentence, speakerID: speaker, confidence: confidence
            )
            currentTime = segEnd
            return seg
        }
    }

    /// Find the speaker active at a given time using binary search + fallback.
    private static func findSpeaker(at time: TimeInterval, in segments: [SpeakerSegment]) -> String {
        // Binary search for the segment containing this time
        var lo = 0, hi = segments.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let seg = segments[mid]
            if time >= seg.startTime && time < seg.endTime {
                return seg.speakerID
            } else if time < seg.startTime {
                hi = mid - 1
            } else {
                lo = mid + 1
            }
        }

        // No exact match — find nearest segment
        var bestDist = Double.infinity
        var bestSpeaker = segments.first?.speakerID ?? "Unknown"
        for seg in segments {
            let dist = min(abs(time - seg.startTime), abs(time - seg.endTime))
            if dist < bestDist {
                bestDist = dist
                bestSpeaker = seg.speakerID
            }
        }
        return bestSpeaker
    }
}
