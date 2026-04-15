// © 2026 High Gain Design. All rights reserved.

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

    // MARK: - Folder CRUD

    /// Return sorted list of top-level folder names.
    public func folders() -> [String] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: baseDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else {
            return []
        }
        return contents
            .filter { url in
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                return isDir
            }
            .map { $0.lastPathComponent }
            .sorted()
    }

    /// Create a new top-level folder. Throws if it already exists.
    public func createFolder(named name: String) throws {
        let sanitized = Self.sanitizeFilename(name)
        guard !sanitized.isEmpty else {
            throw HiDockError.invalidFilename(name)
        }
        let url = baseDirectory.appendingPathComponent(sanitized)
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            throw HiDockError.invalidFilename(name)
        }
        try fm.createDirectory(at: url, withIntermediateDirectories: false)
    }

    /// Rename a top-level folder.
    public func renameFolder(from oldName: String, to newName: String) throws {
        let sanitized = Self.sanitizeFilename(newName)
        guard !sanitized.isEmpty else {
            throw HiDockError.invalidFilename(newName)
        }
        let oldURL = baseDirectory.appendingPathComponent(oldName)
        let newURL = baseDirectory.appendingPathComponent(sanitized)
        try FileManager.default.moveItem(at: oldURL, to: newURL)
    }

    /// Delete a top-level folder and all its contents.
    public func deleteFolder(named name: String) throws {
        let sanitized = Self.sanitizeFilename(name)
        guard !sanitized.isEmpty else { throw HiDockError.invalidFilename(name) }
        let url = baseDirectory.appendingPathComponent(sanitized)
        try FileManager.default.removeItem(at: url)
    }

    // MARK: - Recording scanning

    /// Scan the directory recursively for MP3 files, building metadata with folder info.
    public func allRecordings() -> [RecordingMetadata] {
        scanRecordings(in: baseDirectory, relativeTo: baseDirectory)
    }

    /// Return recordings in a specific folder (relative folder name).
    public func recordings(inFolder folderName: String) -> [RecordingMetadata] {
        let folderURL = baseDirectory.appendingPathComponent(folderName)
        return scanRecordings(in: folderURL, relativeTo: baseDirectory)
    }

    // MARK: - Move recording

    /// Move a recording (and its sidecars) to a folder, or to root if folder is nil.
    /// Returns the new relative filename.
    @discardableResult
    public func moveRecording(filename: String, toFolder folderName: String?) throws -> String {
        let fm = FileManager.default
        let basename = (filename as NSString).lastPathComponent
        let basenameNoExt = (basename as NSString).deletingPathExtension

        // Compute source directory (relative to baseDirectory)
        let oldDir: URL
        let oldFolderPath = (filename as NSString).deletingLastPathComponent
        if oldFolderPath.isEmpty || oldFolderPath == "." {
            oldDir = baseDirectory
        } else {
            oldDir = baseDirectory.appendingPathComponent(oldFolderPath)
        }

        // Compute destination directory
        let newDir: URL
        let newRelativeDir: String
        if let folderName = folderName {
            newDir = baseDirectory.appendingPathComponent(folderName)
            newRelativeDir = folderName
        } else {
            newDir = baseDirectory
            newRelativeDir = ""
        }

        // Compute new relative filename
        let newFilename = newRelativeDir.isEmpty ? basename : "\(newRelativeDir)/\(basename)"

        // Move the MP3 file
        let oldMP3 = oldDir.appendingPathComponent(basename)
        let newMP3 = newDir.appendingPathComponent(basename)
        try fm.moveItem(at: oldMP3, to: newMP3)

        // Move associated sidecar files (best effort)
        for ext in [".transcript.json", ".txt"] {
            let oldSidecar = oldDir.appendingPathComponent("\(basenameNoExt)\(ext)")
            let newSidecar = newDir.appendingPathComponent("\(basenameNoExt)\(ext)")
            if fm.fileExists(atPath: oldSidecar.path) {
                try? fm.moveItem(at: oldSidecar, to: newSidecar)
            }
        }

        return newFilename
    }

    // MARK: - Private helpers

    private func scanRecordings(in directory: URL, relativeTo base: URL) -> [RecordingMetadata] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .creationDateKey, .isDirectoryKey],
            options: .skipsHiddenFiles
        ) else {
            return []
        }

        // Normalize base path for reliable prefix stripping.
        // Use resolvingSymlinksInPath to handle /var -> /private/var on macOS.
        let basePath = base.resolvingSymlinksInPath().path
        let basePrefix = basePath.hasSuffix("/") ? basePath : basePath + "/"

        var results: [RecordingMetadata] = []
        for case let url as URL in enumerator {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir { continue }
            guard url.pathExtension.lowercased() == "mp3" else { continue }

            guard let attrs = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey]) else {
                continue
            }

            // Compute relative path from base; resolve symlinks to match /var -> /private/var
            let normalizedPath = url.resolvingSymlinksInPath().path
            let relativePath: String
            if normalizedPath.hasPrefix(basePrefix) {
                relativePath = String(normalizedPath.dropFirst(basePrefix.count))
            } else {
                relativePath = url.lastPathComponent
            }

            // Determine folder from relative path (first path component if nested)
            let components = relativePath.split(separator: "/", maxSplits: 1)
            let recordingFolder: String? = components.count > 1 ? String(components[0]) : nil

            let fileSize = UInt64(attrs.fileSize ?? 0)
            let parsed = FilenameParsing.parse(url.lastPathComponent)
            let recordedAt = parsed.date ?? attrs.creationDate
            let mode = parsed.mode != .unknown ? parsed.mode.rawValue : ""

            results.append(RecordingMetadata(
                filename: relativePath,
                recordedAt: recordedAt,
                mode: mode,
                fileSizeBytes: fileSize,
                estimatedDuration: DurationCalculator.estimateDuration(fileSize: fileSize),
                folder: recordingFolder
            ))
        }
        return results
    }

    /// Store a downloaded .hda file: convert to .mp3.
    @discardableResult
    public func storeRecording(hdaData: Data, entry: FileEntry) throws -> RecordingMetadata {
        let mp3Filename = entry.filename.replacingOccurrences(of: ".hda", with: ".mp3", options: .caseInsensitive)
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

    /// Delete a local recording and its plain-text sidecar.
    public func deleteRecording(filename: String) throws {
        let url = baseDirectory.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: url)

        // Remove .txt sidecar (best effort)
        let basename = (filename as NSString).deletingPathExtension
        let txtURL = baseDirectory.appendingPathComponent("\(basename).txt")
        try? FileManager.default.removeItem(at: txtURL)
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
