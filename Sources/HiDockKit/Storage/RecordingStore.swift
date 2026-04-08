import Foundation

/// Manages local storage of downloaded recordings.
/// The filesystem is the source of truth — no metadata JSON.
public actor RecordingStore {
    public nonisolated let baseDirectory: URL

    public init(baseDirectory: URL? = nil) {
        if let dir = baseDirectory {
            self.baseDirectory = dir
        } else {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            self.baseDirectory = docs.appendingPathComponent("HiDock Recordings")
        }
    }

    /// Ensure the storage directory exists.
    public func setup() throws {
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
    }

    /// Scan the directory for MP3 files and build metadata from the filesystem.
    public func allRecordings() -> [RecordingMetadata] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: baseDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .creationDateKey],
            options: .skipsHiddenFiles
        ) else {
            return []
        }

        return contents
            .filter { $0.pathExtension.lowercased() == "mp3" }
            .compactMap { url -> RecordingMetadata? in
                guard let attrs = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey]) else {
                    return nil
                }
                let filename = url.lastPathComponent
                let fileSize = UInt64(attrs.fileSize ?? 0)

                // Parse date and mode from filename; fall back to file creation date
                let parsed = FilenameParsing.parse(filename)
                let recordedAt = parsed.date ?? attrs.creationDate
                let mode = parsed.mode != .unknown ? parsed.mode.rawValue : ""

                return RecordingMetadata(
                    filename: filename,
                    recordedAt: recordedAt,
                    mode: mode,
                    fileSizeBytes: fileSize,
                    estimatedDuration: DurationCalculator.estimateDuration(fileSize: fileSize)
                )
            }
    }

    /// Store a downloaded .hda file: convert to .mp3.
    @discardableResult
    public func storeRecording(hdaData: Data, entry: FileEntry) throws -> RecordingMetadata {
        let mp3Filename = entry.filename.replacingOccurrences(of: ".hda", with: ".mp3")
        let outputURL = baseDirectory.appendingPathComponent(mp3Filename)

        try HDAConverter.convertAndWrite(hdaData: hdaData, to: outputURL)

        // Read back metadata from the file we just wrote
        let attrs = try outputURL.resourceValues(forKeys: [.fileSizeKey, .creationDateKey])
        let fileSize = UInt64(attrs.fileSize ?? 0)
        let parsed = FilenameParsing.parse(mp3Filename)

        return RecordingMetadata(
            filename: mp3Filename,
            recordedAt: parsed.date ?? attrs.creationDate,
            mode: parsed.mode != .unknown ? parsed.mode.rawValue : "",
            fileSizeBytes: fileSize,
            estimatedDuration: DurationCalculator.estimateDuration(fileSize: fileSize)
        )
    }

    /// Delete a local recording.
    public func deleteRecording(filename: String) throws {
        let url = baseDirectory.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: url)
    }

    /// Rename a recording file on disk, plus the associated transcript file.
    /// Returns the new filename.
    @discardableResult
    public func renameRecording(filename: String, to newName: String) throws -> String {
        let oldBasename = (filename as NSString).deletingPathExtension
        let sanitized = Self.sanitizeFilename(newName.hasSuffix(".mp3") ? String(newName.dropLast(4)) : newName)
        guard !sanitized.isEmpty else {
            throw HiDockError.invalidFilename(newName)
        }
        let newFilename = "\(sanitized).mp3"
        let newBasename = sanitized

        guard filename != newFilename else { return filename }

        let fm = FileManager.default

        // Rename the MP3 file
        let oldURL = baseDirectory.appendingPathComponent(filename)
        let newURL = baseDirectory.appendingPathComponent(newFilename)
        try fm.moveItem(at: oldURL, to: newURL)

        // Rename associated files (best effort)
        for ext in [".transcript.json", ".txt"] {
            let oldAssoc = baseDirectory.appendingPathComponent("\(oldBasename)\(ext)")
            let newAssoc = baseDirectory.appendingPathComponent("\(newBasename)\(ext)")
            try? fm.moveItem(at: oldAssoc, to: newAssoc)
        }

        return newFilename
    }

    /// Get the file URL for a recording's MP3.
    public func mp3URL(for metadata: RecordingMetadata) -> URL {
        baseDirectory.appendingPathComponent(metadata.filename)
    }

    /// Sanitize a filename by replacing illegal characters.
    static func sanitizeFilename(_ name: String) -> String {
        // Replace characters illegal in macOS/Windows filenames
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|\0")
        let sanitized = name.unicodeScalars
            .filter { !illegal.contains($0) }
            .map { Character($0) }
        return String(sanitized).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Check if a recording has already been downloaded.
    /// Accepts either HDA or MP3 filename — converts HDA to MP3 for the check.
    public func isDownloaded(filename: String) -> Bool {
        let mp3Name = filename.hasSuffix(".hda")
            ? filename.replacingOccurrences(of: ".hda", with: ".mp3")
            : filename
        let url = baseDirectory.appendingPathComponent(mp3Name)
        return FileManager.default.fileExists(atPath: url.path)
    }
}
