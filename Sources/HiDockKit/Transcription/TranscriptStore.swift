import Foundation

/// Persists transcripts as JSON files alongside recordings.
/// Each transcript is stored as `{recording_basename}.transcript.json`.
/// Cache is keyed by MP3 filename.
public actor TranscriptStore {
    private let baseDirectory: URL
    private var cache: [String: Transcript] = [:]  // keyed by MP3 filename
    private var dirtyTxtFiles: Set<String> = []
    private var txtFlushTask: Task<Void, Never>?

    public init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

    /// Load all transcripts from disk (recursively, including subfolders).
    public func loadAll() throws {
        cache.removeAll()
        let fm = FileManager.default
        guard fm.fileExists(atPath: baseDirectory.path) else { return }

        guard let enumerator = fm.enumerator(
            at: baseDirectory,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return }

        // Use resolvingSymlinksInPath to handle /var -> /private/var on macOS.
        let basePath = baseDirectory.resolvingSymlinksInPath().path
        let basePrefix = basePath.hasSuffix("/") ? basePath : basePath + "/"

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for case let file as URL in enumerator {
            guard file.pathExtension == "json",
                  file.lastPathComponent.contains(".transcript.") else { continue }
            do {
                let data = try Data(contentsOf: file)
                let transcript = try decoder.decode(Transcript.self, from: data)
                // Derive folder-relative mp3 key by stripping base directory
                let resolvedPath = file.resolvingSymlinksInPath().path
                let relativePath = resolvedPath.hasPrefix(basePrefix)
                    ? String(resolvedPath.dropFirst(basePrefix.count))
                    : file.lastPathComponent
                let mp3Key = relativePath.replacingOccurrences(of: ".transcript.json", with: ".mp3")
                cache[mp3Key] = transcript
            } catch {
                // Skip corrupt transcript files rather than aborting the entire load
                continue
            }
        }

        // Detect and regenerate stale TXT files
        for (mp3Key, _) in cache {
            let basename = (mp3Key as NSString).deletingPathExtension
            let jsonURL = baseDirectory.appendingPathComponent("\(basename).transcript.json")
            let txtURL = baseDirectory.appendingPathComponent("\(basename).txt")

            guard fm.fileExists(atPath: txtURL.path) else {
                dirtyTxtFiles.insert(mp3Key)
                continue
            }

            let jsonMod = (try? fm.attributesOfItem(atPath: jsonURL.path)[.modificationDate] as? Date) ?? .distantPast
            let txtMod = (try? fm.attributesOfItem(atPath: txtURL.path)[.modificationDate] as? Date) ?? .distantFuture

            if jsonMod > txtMod {
                dirtyTxtFiles.insert(mp3Key)
            }
        }

        if !dirtyTxtFiles.isEmpty {
            flushPendingTxtWrites()
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
    public func rename(from oldMp3: String, to newMp3: String) {
        guard let transcript = cache.removeValue(forKey: oldMp3) else { return }
        cache[newMp3] = transcript
        // The actual file rename is handled by RecordingStore.renameRecording
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
