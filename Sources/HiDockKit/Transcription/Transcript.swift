import Foundation

/// A complete transcript of a recording, with speaker-labeled segments.
public struct Transcript: Codable, Sendable, Identifiable {
    public var id: String { recordingFilename }

    /// The recording this transcript belongs to.
    public let recordingFilename: String

    /// When this transcript was generated.
    public let createdAt: Date

    /// The model/engine used for transcription (e.g., "parakeet-tdt-1.0").
    public let transcriptionModel: String

    /// Whether speaker diarization was applied.
    public let hasSpeakerLabels: Bool

    /// Ordered segments of the transcript.
    public var segments: [Segment]

    /// Known speaker labels (e.g., ["Speaker 1": "Analyst", "Speaker 2": "CEO"]).
    /// Users can rename speakers after transcription.
    public var speakerNames: [String: String]

    /// Language detected or specified.
    public var language: String?

    public init(
        recordingFilename: String,
        createdAt: Date = Date(),
        transcriptionModel: String,
        hasSpeakerLabels: Bool,
        segments: [Segment],
        speakerNames: [String: String] = [:],
        language: String? = nil
    ) {
        self.recordingFilename = recordingFilename
        self.createdAt = createdAt
        self.transcriptionModel = transcriptionModel
        self.hasSpeakerLabels = hasSpeakerLabels
        self.segments = segments
        self.speakerNames = speakerNames
        self.language = language
    }
}

extension Transcript {
    /// A single segment of transcribed speech.
    public struct Segment: Codable, Sendable, Identifiable {
        public let id: UUID
        public let startTime: TimeInterval   // seconds from start
        public let endTime: TimeInterval
        public let text: String
        public let speakerID: String?        // e.g., "Speaker 1", "Speaker 2"
        public let confidence: Float?        // 0.0–1.0

        public init(
            id: UUID = UUID(),
            startTime: TimeInterval,
            endTime: TimeInterval,
            text: String,
            speakerID: String? = nil,
            confidence: Float? = nil
        ) {
            self.id = id
            self.startTime = startTime
            self.endTime = endTime
            self.text = text
            self.speakerID = speakerID
            self.confidence = confidence
        }

        /// Duration of this segment in seconds.
        public var duration: TimeInterval { endTime - startTime }

        /// Display name for the speaker, using custom name if available.
        public func speakerDisplayName(from names: [String: String]) -> String {
            guard let sid = speakerID else { return "Unknown" }
            return names[sid] ?? sid
        }
    }
}

extension Transcript {
    /// Full text of the transcript, optionally with speaker labels.
    public func plainText(includeSpeakers: Bool = true) -> String {
        segments.map { seg in
            if includeSpeakers, let sid = seg.speakerID {
                let name = speakerNames[sid] ?? sid
                return "[\(name)] \(seg.text)"
            }
            return seg.text
        }.joined(separator: "\n")
    }

    /// All unique speaker IDs in this transcript.
    public var speakerIDs: [String] {
        Array(Set(segments.compactMap(\.speakerID))).sorted()
    }

    /// Total duration of transcribed audio.
    public var totalDuration: TimeInterval {
        segments.last?.endTime ?? 0
    }

    /// Segments for a specific speaker.
    public func segments(for speakerID: String) -> [Segment] {
        segments.filter { $0.speakerID == speakerID }
    }
}
