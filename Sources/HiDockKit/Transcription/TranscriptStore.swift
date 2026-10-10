// © 2026 High Gain Design. All rights reserved.

import Foundation

/// Persists transcripts as JSON files alongside recordings.
/// Each transcript is stored as `{recording_basename}.transcript.json`.
/// Cache is keyed by MP3 filename.
public actor TranscriptStore {
    private let baseDirectory: URL
    private let fileAccess: RecordingFileAccess
    private var revisions: [String: Int] = [:]
    private var cache: [String: Transcript] = [:]  // keyed by MP3 filename
    private var dirtyTxtFiles: Set<String> = []
    private var txtFlushTask: Task<Void, Never>?

    public init(baseDirectory: URL, fileAccess: RecordingFileAccess = RecordingFileAccess()) {
        self.baseDirectory = baseDirectory
        self.fileAccess = fileAccess
    }

    /// Set of MP3 filenames that have transcript files on disk.
    private var knownFiles: Set<String> = []

    /// Scan for transcript files (existence only, no parsing). Fast startup.
    public func loadAll() throws {
        knownFiles = Set(LibraryFileDiscovery.files(in: baseDirectory, suffix: ".transcript.json").map {
            String($0.relativePath.dropLast(".transcript.json".count)) + ".mp3"
        })
    }

    /// Load a single transcript from disk on demand.
    private func loadFromDisk(mp3Filename: String, knownToExist: Bool = false,
                              onWaiting: @Sendable () async -> Void = {}) async throws -> Transcript? {
        let url = fileURL(for: mp3Filename)
        guard let data = try await fileAccess.readDataIfPresent(at: url, knownToExist: knownToExist, onWaiting: onWaiting) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Transcript.self, from: data)
    }

    /// Save a transcript, keyed by MP3 filename.
    public func save(_ transcript: Transcript, mp3Filename: String) throws {
        let url = fileURL(for: mp3Filename)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(transcript)
        try data.write(to: url, options: .atomic)
        revisions[mp3Filename, default: 0] += 1
        cache[mp3Filename] = transcript
        knownFiles.insert(mp3Filename)
    }

    /// Get a transcript for a recording by MP3 filename.
    public func transcript(for mp3Filename: String) async -> Transcript? {
        try? await loadTranscript(for: mp3Filename)
    }

    /// Throwing UI load distinguishes a missing sidecar from download/read errors.
    public func loadTranscript(for mp3Filename: String,
                               onWaiting: @Sendable () async -> Void = {}) async throws -> Transcript? {
        if let cached = cache[mp3Filename] { return cached }
        let revision = revisions[mp3Filename, default: 0]
        let loaded = try await loadFromDisk(mp3Filename: mp3Filename,
                                            knownToExist: knownFiles.contains(mp3Filename), onWaiting: onWaiting)
        try Task.checkCancellation()
        guard revisions[mp3Filename, default: 0] == revision else { return cache[mp3Filename] }
        if let loaded { cache[mp3Filename] = loaded }
        return loaded
    }

    /// Check if a transcript exists for a recording (fast, no parsing).
    public func hasTranscript(for mp3Filename: String) -> Bool {
        cache[mp3Filename] != nil || knownFiles.contains(mp3Filename)
    }

    /// Delete a transcript.
    public func delete(for mp3Filename: String) throws {
        let url = fileURL(for: mp3Filename)
        try? FileManager.default.removeItem(at: url)
        revisions[mp3Filename, default: 0] += 1
        cache.removeValue(forKey: mp3Filename)
        knownFiles.remove(mp3Filename)
    }

    /// All available transcripts.
    public func allTranscripts() -> [Transcript] {
        Array(cache.values)
    }

    /// All MP3 filenames that have transcripts (from disk scan, no parsing).
    public func allTranscribedFilenames() -> [String] {
        Array(knownFiles)
    }

    /// Update speaker names in a transcript. JSON is written immediately; TXT regeneration is debounced.
    public func updateSpeakerNames(for mp3Filename: String, names: [String: String]) throws {
        guard var transcript = cache[mp3Filename] else { return }
        transcript.speakerNames = names
        try save(transcript, mp3Filename: mp3Filename)
        markTxtDirty(mp3Filename)
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
        markTxtDirty(mp3Filename)
    }

    /// Split a speaker at a specific segment, assigning a new speaker ID.
    /// If `allFollowing` is true, all segments from this one to the end that share the same speaker ID get the new ID.
    /// If `allFollowing` is false, only the specific segment gets the new ID.
    public func splitSpeaker(for mp3Filename: String, segmentID: UUID, allFollowing: Bool) throws {
        guard var transcript = cache[mp3Filename] else { return }
        guard let segIndex = transcript.segments.firstIndex(where: { $0.id == segmentID }),
              let oldSID = transcript.segments[segIndex].speakerID else { return }

        // Generate a new unique speaker ID
        let existingIDs = Set(transcript.segments.compactMap(\.speakerID))
        var newSID = "\(oldSID)_2"
        var counter = 2
        while existingIDs.contains(newSID) {
            counter += 1
            newSID = "\(oldSID)_\(counter)"
        }

        if allFollowing {
            // Reassign all segments from segIndex onward that have the old speaker ID
            for i in segIndex..<transcript.segments.count {
                if transcript.segments[i].speakerID == oldSID {
                    let seg = transcript.segments[i]
                    transcript.segments[i] = Transcript.Segment(
                        id: seg.id, startTime: seg.startTime, endTime: seg.endTime,
                        text: seg.text, speakerID: newSID, confidence: seg.confidence
                    )
                }
            }
        } else {
            // Only reassign the specific segment
            let seg = transcript.segments[segIndex]
            transcript.segments[segIndex] = Transcript.Segment(
                id: seg.id, startTime: seg.startTime, endTime: seg.endTime,
                text: seg.text, speakerID: newSID, confidence: seg.confidence
            )
        }

        // Copy the speaker name from the old ID
        if let oldName = transcript.speakerNames[oldSID] {
            transcript.speakerNames[newSID] = "\(oldName) (split)"
        } else {
            transcript.speakerNames[newSID] = newSID
        }

        try save(transcript, mp3Filename: mp3Filename)
        markTxtDirty(mp3Filename)
    }

    /// Re-key a transcript after a recording rename.
    public func rename(from oldMp3: String, to newMp3: String) async throws {
        var loaded = cache[oldMp3]
        if loaded == nil { loaded = try await loadFromDisk(mp3Filename: newMp3) }
        if loaded == nil { loaded = try await loadFromDisk(mp3Filename: oldMp3) }
        guard let transcript = loaded else { return }
        let updated = Transcript(
            recordingFilename: newMp3, createdAt: transcript.createdAt,
            transcriptionModel: transcript.transcriptionModel,
            hasSpeakerLabels: transcript.hasSpeakerLabels, segments: transcript.segments,
            speakerNames: transcript.speakerNames, language: transcript.language
        )
        try save(updated, mp3Filename: newMp3)
        if oldMp3 != newMp3 {
            revisions[oldMp3, default: 0] += 1
            cache.removeValue(forKey: oldMp3)
            knownFiles.remove(oldMp3)
            try? FileManager.default.removeItem(at: fileURL(for: oldMp3))
        }
        dirtyTxtFiles.remove(oldMp3)
        markTxtDirty(newMp3)
    }

    /// Flush all pending TXT writes immediately, cancelling any scheduled debounce.
    public func flushPendingTxtWrites() {
        txtFlushTask?.cancel()
        txtFlushTask = nil
        for mp3Filename in dirtyTxtFiles {
            if let transcript = cache[mp3Filename] {
                try? exportPlainText(transcript, mp3Filename: mp3Filename)
            }
        }
        dirtyTxtFiles.removeAll()
    }

    private func markTxtDirty(_ mp3Filename: String) {
        dirtyTxtFiles.insert(mp3Filename)
        txtFlushTask?.cancel()
        txtFlushTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            flushPendingTxtWrites()
        }
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
