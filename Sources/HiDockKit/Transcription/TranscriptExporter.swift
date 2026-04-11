// © 2026 High Gain Design. All rights reserved.

import Foundation

/// Exports transcripts in formats suitable for downstream processing:
/// vector DB ingestion, LLM context, structured search, etc.
public enum TranscriptExporter {

    /// A single chunk for vector DB ingestion.
    /// Each chunk is a self-contained unit of context with full metadata.
    public struct VectorChunk: Codable, Sendable {
        public let id: String              // unique chunk ID
        public let recordingFilename: String
        public let recordedAt: String?     // ISO 8601
        public let speaker: String         // display name or speaker ID
        public let speakerID: String?      // raw speaker ID
        public let startTime: Double       // seconds
        public let endTime: Double
        public let text: String
        public let mode: String            // Rec, Pho, Mee, etc.
        public let chunkIndex: Int
        public let totalChunks: Int
    }

    /// Export a transcript as vector-DB-ready JSON Lines (one JSON object per line).
    /// Each line is a self-contained chunk with metadata for filtering/faceting.
    ///
    /// Chunking strategy: group consecutive segments by the same speaker into
    /// single chunks, respecting a max character limit to keep chunks embeddable.
    public static func exportJSONLines(
        transcript: Transcript,
        recordingMetadata: RecordingMetadata? = nil,
        maxChunkChars: Int = 1500
    ) -> Data {
        let chunks = chunkTranscript(transcript: transcript, recordingMetadata: recordingMetadata, maxChunkChars: maxChunkChars)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        var lines: [Data] = []
        for chunk in chunks {
            if let data = try? encoder.encode(chunk) {
                lines.append(data)
            }
        }

        return lines.map { $0 }.joined(separator: Data("\n".utf8))
    }

    /// Export as structured JSON array (for bulk API calls, debugging, etc.).
    public static func exportJSON(
        transcript: Transcript,
        recordingMetadata: RecordingMetadata? = nil,
        maxChunkChars: Int = 1500
    ) -> Data {
        let chunks = chunkTranscript(transcript: transcript, recordingMetadata: recordingMetadata, maxChunkChars: maxChunkChars)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(chunks)) ?? Data()
    }

    /// Export as plain text with speaker labels and timestamps.
    public static func exportPlainText(transcript: Transcript) -> String {
        var lines: [String] = []
        var currentSpeaker: String?

        for seg in transcript.segments {
            let speaker = seg.speakerID.flatMap { transcript.speakerNames[$0] ?? $0 } ?? "Unknown"
            let timestamp = formatTimestamp(seg.startTime)

            if speaker != currentSpeaker {
                if !lines.isEmpty { lines.append("") }
                lines.append("[\(timestamp)] \(speaker):")
                currentSpeaker = speaker
            }

            lines.append(seg.text)
        }

        return lines.joined(separator: "\n")
    }

    /// Export as SRT subtitle format (useful for review/correction).
    public static func exportSRT(transcript: Transcript) -> String {
        var srt = ""
        for (i, seg) in transcript.segments.enumerated() {
            let speaker = seg.speakerID.flatMap { transcript.speakerNames[$0] ?? $0 }
            let prefix = speaker.map { "[\($0)] " } ?? ""
            srt += "\(i + 1)\n"
            srt += "\(srtTimestamp(seg.startTime)) --> \(srtTimestamp(seg.endTime))\n"
            srt += "\(prefix)\(seg.text)\n\n"
        }
        return srt
    }

    // MARK: - Chunking

    /// Groups consecutive same-speaker segments into chunks, splitting at maxChunkChars.
    static func chunkTranscript(
        transcript: Transcript,
        recordingMetadata: RecordingMetadata?,
        maxChunkChars: Int
    ) -> [VectorChunk] {
        let parsed = FilenameParsing.parse(transcript.recordingFilename)
        let mode = parsed.mode.rawValue
        let recordedAt = parsed.date.map { ISO8601DateFormatter().string(from: $0) }

        // Group consecutive segments by speaker
        var groups: [(speaker: String, speakerID: String?, segments: [Transcript.Segment])] = []
        for seg in transcript.segments {
            let sid = seg.speakerID ?? "Unknown"
            let displayName = seg.speakerDisplayName(from: transcript.speakerNames)
            if let last = groups.last, last.speakerID == seg.speakerID {
                groups[groups.count - 1].segments.append(seg)
            } else {
                groups.append((speaker: displayName, speakerID: seg.speakerID, segments: [seg]))
            }
        }

        // Split groups that exceed maxChunkChars
        var chunks: [VectorChunk] = []
        for group in groups {
            var currentText = ""
            var currentStart = group.segments.first?.startTime ?? 0
            var currentEnd = currentStart

            for seg in group.segments {
                let addition = (currentText.isEmpty ? "" : " ") + seg.text
                if currentText.count + addition.count > maxChunkChars && !currentText.isEmpty {
                    // Flush current chunk
                    chunks.append(VectorChunk(
                        id: "", recordingFilename: transcript.recordingFilename,
                        recordedAt: recordedAt, speaker: group.speaker,
                        speakerID: group.speakerID, startTime: currentStart,
                        endTime: currentEnd, text: currentText, mode: mode,
                        chunkIndex: 0, totalChunks: 0
                    ))
                    currentText = seg.text
                    currentStart = seg.startTime
                } else {
                    currentText += addition
                }
                currentEnd = seg.endTime
            }

            if !currentText.isEmpty {
                chunks.append(VectorChunk(
                    id: "", recordingFilename: transcript.recordingFilename,
                    recordedAt: recordedAt, speaker: group.speaker,
                    speakerID: group.speakerID, startTime: currentStart,
                    endTime: currentEnd, text: currentText, mode: mode,
                    chunkIndex: 0, totalChunks: 0
                ))
            }
        }

        // Assign IDs and indices
        let total = chunks.count
        let basename = (transcript.recordingFilename as NSString).deletingPathExtension
        return chunks.enumerated().map { i, chunk in
            VectorChunk(
                id: "\(basename)_chunk\(i)",
                recordingFilename: chunk.recordingFilename,
                recordedAt: chunk.recordedAt,
                speaker: chunk.speaker,
                speakerID: chunk.speakerID,
                startTime: chunk.startTime,
                endTime: chunk.endTime,
                text: chunk.text,
                mode: chunk.mode,
                chunkIndex: i,
                totalChunks: total
            )
        }
    }

    // MARK: - Formatting

    private static func formatTimestamp(_ seconds: TimeInterval) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    private static func srtTimestamp(_ seconds: TimeInterval) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        let ms = Int((seconds - Double(Int(seconds))) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }
}

private extension Array where Element == Data {
    func joined(separator: Data) -> Data {
        guard let first = self.first else { return Data() }
        return dropFirst().reduce(into: first) { result, element in
            result.append(separator)
            result.append(element)
        }
    }
}
