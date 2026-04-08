import Foundation

/// Persists transcripts as JSON files alongside recordings.
/// Each transcript is stored as `{recording_basename}.transcript.json`.
/// Cache is keyed by MP3 filename.
public actor TranscriptStore {
    private let baseDirectory: URL
    private var cache: [String: Transcript] = [:]  // keyed by MP3 filename

    public init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

    /// Load all transcripts from disk.
    public func loadAll() throws {
        cache.removeAll()
        let fm = FileManager.default
        guard fm.fileExists(atPath: baseDirectory.path) else { return }

        let files = try fm.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: nil)
        for file in files where file.pathExtension == "json" && file.lastPathComponent.contains(".transcript.") {
            let data = try Data(contentsOf: file)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let transcript = try decoder.decode(Transcript.self, from: data)
            // Key by MP3 filename derived from the transcript file name
            let basename = file.lastPathComponent
                .replacingOccurrences(of: ".transcript.json", with: "")
            let mp3Key = "\(basename).mp3"
            cache[mp3Key] = transcript
        }
    }

    /// Save a transcript, keyed by MP3 filename.
    public func save(_ transcript: Transcript, mp3Filename: String) throws {
        let url = fileURL(for: mp3Filename)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(transcript)
        try data.write(to: url)
        cache[mp3Filename] = transcript
    }

    /// Get a transcript for a recording by MP3 filename.
    public func transcript(for mp3Filename: String) -> Transcript? {
        cache[mp3Filename]
    }

    /// Check if a transcript exists for a recording.
    public func hasTranscript(for mp3Filename: String) -> Bool {
        cache[mp3Filename] != nil
    }

    /// Delete a transcript.
    public func delete(for mp3Filename: String) throws {
        let url = fileURL(for: mp3Filename)
        try? FileManager.default.removeItem(at: url)
        cache.removeValue(forKey: mp3Filename)
    }

    /// All available transcripts.
    public func allTranscripts() -> [Transcript] {
        Array(cache.values)
    }

    /// Update speaker names in a transcript and regenerate .txt export.
    public func updateSpeakerNames(for mp3Filename: String, names: [String: String]) throws {
        guard var transcript = cache[mp3Filename] else { return }
        transcript.speakerNames = names
        try save(transcript, mp3Filename: mp3Filename)
        try exportPlainText(transcript, mp3Filename: mp3Filename)
    }

    /// Merge speaker IDs: reassign all segments from `sourceID` to `targetID`, remove sourceID from names.
    public func mergeSpeakers(for mp3Filename: String, source sourceID: String, into targetID: String) throws {
        guard var transcript = cache[mp3Filename] else { return }
        transcript.segments = transcript.segments.map { seg in
            guard seg.speakerID == sourceID else { return seg }
            return Transcript.Segment(
                id: seg.id, startTime: seg.startTime, endTime: seg.endTime,
                text: seg.text, speakerID: targetID, confidence: seg.confidence
            )
        }
        // Keep target's name, remove source
        transcript.speakerNames.removeValue(forKey: sourceID)
        try save(transcript, mp3Filename: mp3Filename)
        try exportPlainText(transcript, mp3Filename: mp3Filename)
    }

    /// Re-key a transcript after a recording rename.
    public func rename(from oldMp3: String, to newMp3: String) {
        guard let transcript = cache.removeValue(forKey: oldMp3) else { return }
        cache[newMp3] = transcript
        // The actual file rename is handled by RecordingStore.renameRecording
    }

    private func exportPlainText(_ transcript: Transcript, mp3Filename: String) throws {
        let basename = (mp3Filename as NSString).deletingPathExtension
        let txtURL = baseDirectory.appendingPathComponent("\(basename).txt")
        let plainText = TranscriptExporter.exportPlainText(transcript: transcript)
        try plainText.write(to: txtURL, atomically: true, encoding: .utf8)
    }

    private func fileURL(for mp3Filename: String) -> URL {
        let basename = (mp3Filename as NSString).deletingPathExtension
        return baseDirectory.appendingPathComponent("\(basename).transcript.json")
    }
}
