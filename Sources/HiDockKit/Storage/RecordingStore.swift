// © 2026 High Gain Design. All rights reserved.

import Foundation

/// Manages local storage of downloaded recordings.
/// Audio files are canonical; library.json preserves metadata through renames.
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

    /// Ensure the storage directory exists and load persisted metadata.
    public func setup() throws {
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        loadLibraryMeta()
    }

    // MARK: - Folder CRUD

    /// Return sorted list of top-level folder names.
    public func folders() -> [String] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: baseDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else {
            return []
        }
        return contents
            .filter { url in
                guard !url.lastPathComponent.hasPrefix(".") else { return false }
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
    @discardableResult
    public func renameFolder(from oldName: String, to newName: String) throws -> String {
        let sanitized = Self.sanitizeFilename(newName)
        guard !sanitized.isEmpty else {
            throw HiDockError.invalidFilename(newName)
        }
        let oldURL = baseDirectory.appendingPathComponent(oldName)
        let newURL = baseDirectory.appendingPathComponent(sanitized)
        try FileManager.default.moveItem(at: oldURL, to: newURL)
        return sanitized
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

        guard filename != newFilename else { return filename }
        try requireAvailableRecordingPath(newFilename)

        // Move the MP3 file
        let oldMP3 = oldDir.appendingPathComponent(basename)
        let newMP3 = newDir.appendingPathComponent(basename)
        try fm.moveItem(at: oldMP3, to: newMP3)

        // Move associated sidecar files (best effort)
        for ext in [".transcript.json", ".summary.json", ".txt"] {
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
        var results: [RecordingMetadata] = []
        for file in LibraryFileDiscovery.files(in: directory, relativeTo: base, suffix: ".mp3") {
            let url = file.url
            if file.isPlaceholder {
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            }
            guard let attrs = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey]) else {
                continue
            }
            let realLastComponent = file.logicalName
            let relativePath = file.relativePath

            // Determine folder from relative path (first path component if nested)
            let components = relativePath.split(separator: "/", maxSplits: 1)
            let recordingFolder: String? = components.count > 1 ? String(components[0]) : nil

            let fileSize = UInt64(attrs.fileSize ?? 0)
            let parsed = FilenameParsing.parse(realLastComponent)
            let recordMeta = meta[realLastComponent]
            let originalDate = recordMeta?.deviceFilename.flatMap { FilenameParsing.parse($0).date }
            let recordedAt = recordMeta?.recordedAt ?? parsed.date ?? originalDate ?? attrs.creationDate
            let mode: String
            if parsed.mode != .unknown {
                mode = parsed.mode.rawValue
            } else {
                mode = meta[realLastComponent]?.mode ?? ""
            }

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
        let mode = parsed.mode != .unknown ? parsed.mode.rawValue : ""

        // Persist mode and original device filename so they survive renames
        setMeta(mode: mode, deviceFilename: entry.filename, for: mp3Filename)

        return RecordingMetadata(
            filename: mp3Filename,
            recordedAt: parsed.date ?? attrs.creationDate,
            mode: mode,
            fileSizeBytes: fileSize,
            estimatedDuration: DurationCalculator.estimateDuration(fileSize: fileSize)
        )
    }

    // MARK: - Merge recordings

    /// Merge encoded audio frames, rebuilding duration metadata without re-encoding.
    /// Files are concatenated in the order provided. Returns metadata for the merged recording.
    @discardableResult
    public func mergeRecordings(filenames: [String], as newFilename: String) throws -> RecordingMetadata {
        guard filenames.count >= 2 else {
            throw HiDockError.invalidFilename("Need at least 2 recordings to merge")
        }

        let sanitized = Self.sanitizeFilename(newFilename.hasSuffix(".mp3") ? String(newFilename.dropLast(4)) : newFilename)
        guard !sanitized.isEmpty else {
            throw HiDockError.invalidFilename(newFilename)
        }
        let outputFilename = "\(sanitized).mp3"
        let outputURL = baseDirectory.appendingPathComponent(outputFilename)
        try requireAvailableRecordingPath(outputFilename)

        var concatenator = MP3Concatenator()
        var earliestDate: Date?
        var firstMode: String = ""

        for (index, filename) in filenames.enumerated() {
            let url = baseDirectory.appendingPathComponent(filename)
            let data = try Data(contentsOf: url)
            try concatenator.append(data)

            // Get metadata from first file for mode, earliest date from all
            let parsed = FilenameParsing.parse((filename as NSString).lastPathComponent)
            let attrs = try? url.resourceValues(forKeys: [.creationDateKey])
            let originalMeta = meta[(filename as NSString).lastPathComponent]
            let originalDate = originalMeta?.deviceFilename.flatMap { FilenameParsing.parse($0).date }
            let date = originalMeta?.recordedAt ?? parsed.date ?? originalDate ?? attrs?.creationDate

            if let date {
                if earliestDate == nil || date < earliestDate! {
                    earliestDate = date
                }
            }
            if index == 0 {
                firstMode = parsed.mode != .unknown ? parsed.mode.rawValue : (mode(for: filename) ?? "")
            }
        }

        let mergedData = try concatenator.output()
        try mergedData.write(to: outputURL, options: .atomic)

        let fileSize = UInt64(mergedData.count)

        // Record metadata
        let metaEntry = RecordingMeta(
            mode: firstMode.isEmpty ? nil : firstMode,
            deviceFilename: nil,
            mergedFrom: filenames.map { ($0 as NSString).lastPathComponent },
            recordedAt: earliestDate
        )
        meta[outputURL.lastPathComponent] = metaEntry
        saveLibraryMeta()

        return RecordingMetadata(
            filename: outputFilename,
            recordedAt: earliestDate,
            mode: firstMode,
            fileSizeBytes: fileSize,
            estimatedDuration: DurationCalculator.estimateDuration(fileSize: fileSize)
        )
    }

    /// Delete a local recording and all its sidecars.
    public func deleteRecordingAndSidecars(filename: String) throws {
        let basename = ((filename as NSString).lastPathComponent as NSString).deletingPathExtension
        let dir: URL
        let folderPath = (filename as NSString).deletingLastPathComponent
        if folderPath.isEmpty || folderPath == "." {
            dir = baseDirectory
        } else {
            dir = baseDirectory.appendingPathComponent(folderPath)
        }

        for ext in [".mp3", ".transcript.json", ".summary.json", ".txt"] {
            let url = dir.appendingPathComponent("\(basename)\(ext)")
            try? FileManager.default.removeItem(at: url)
        }
        removeMeta(for: filename)
    }

    /// Delete a local recording and its plain-text sidecar.
    public func deleteRecording(filename: String) throws {
        let url = baseDirectory.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: url)

        // Remove .txt sidecar (best effort)
        let basename = (filename as NSString).deletingPathExtension
        let txtURL = baseDirectory.appendingPathComponent("\(basename).txt")
        try? FileManager.default.removeItem(at: txtURL)

        removeMeta(for: filename)
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
        let folder = (filename as NSString).deletingLastPathComponent
        let newFilename = folder.isEmpty || folder == "."
            ? "\(sanitized).mp3" : "\(folder)/\(sanitized).mp3"
        let newBasename = (newFilename as NSString).deletingPathExtension

        guard filename != newFilename else { return filename }

        let fm = FileManager.default

        try requireAvailableRecordingPath(newFilename)

        // Rename the MP3 file
        let oldURL = baseDirectory.appendingPathComponent(filename)
        let newURL = baseDirectory.appendingPathComponent(newFilename)
        try fm.moveItem(at: oldURL, to: newURL)

        // Rename associated files (best effort)
        for ext in [".transcript.json", ".summary.json", ".txt"] {
            let oldAssoc = baseDirectory.appendingPathComponent("\(oldBasename)\(ext)")
            let newAssoc = baseDirectory.appendingPathComponent("\(newBasename)\(ext)")
            try? fm.moveItem(at: oldAssoc, to: newAssoc)
        }

        let oldKey = (filename as NSString).lastPathComponent
        if meta[oldKey] == nil {
            let parsed = FilenameParsing.parse(oldKey)
            meta[oldKey] = RecordingMeta(
                mode: parsed.mode == .unknown ? nil : parsed.mode.rawValue,
                deviceFilename: parsed.date == nil ? nil : (oldKey as NSString).deletingPathExtension + ".hda",
                recordedAt: parsed.date ?? (try? newURL.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            )
        }
        if meta[oldKey]?.deviceFilename == nil, FilenameParsing.parse(oldKey).date != nil {
            meta[oldKey]?.deviceFilename = (oldKey as NSString).deletingPathExtension + ".hda"
        }
        renameMeta(from: filename, to: newFilename)
        return newFilename
    }

    /// Get the file URL for a recording's MP3.
    public func mp3URL(for metadata: RecordingMetadata) -> URL {
        baseDirectory.appendingPathComponent(metadata.filename)
    }

    // MARK: - Recording metadata (library.json)

    /// Per-recording metadata that survives renames. Keyed by current filename.
    public struct RecordingMeta: Codable {
        public var mode: String?
        public var deviceFilename: String?
        public var mergedFrom: [String]?
        public var recordedAt: Date?
    }

    /// In-memory cache of filename → metadata.
    private var meta: [String: RecordingMeta] = [:]

    /// Load library.json from disk. Also migrates modes.json if present.
    public func loadLibraryMeta() {
        // Migrate from modes.json if it exists
        let modesURL = baseDirectory.appendingPathComponent("modes.json")
        if let data = try? Data(contentsOf: modesURL),
           let dict = try? JSONDecoder().decode([String: String].self, from: data) {
            for (key, mode) in dict {
                meta[key] = RecordingMeta(mode: mode, deviceFilename: nil)
            }
            saveLibraryMeta()
            try? FileManager.default.removeItem(at: modesURL)
        }

        let url = baseDirectory.appendingPathComponent("library.json")
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: RecordingMeta].self, from: data) else {
            return
        }
        meta = dict
    }

    /// Save library.json to disk.
    private func saveLibraryMeta() {
        let url = baseDirectory.appendingPathComponent("library.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(meta) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Record metadata for a downloaded file. Call after storeRecording.
    public func setMeta(mode: String, deviceFilename: String, for filename: String) {
        let key = (filename as NSString).lastPathComponent
        meta[key] = RecordingMeta(mode: mode.isEmpty ? nil : mode, deviceFilename: deviceFilename)
        saveLibraryMeta()
    }

    /// Look up the persisted mode for a filename.
    public func mode(for filename: String) -> String? {
        let key = (filename as NSString).lastPathComponent
        return meta[key]?.mode
    }

    /// All device filenames that have been imported (for synchronous download checks).
    public func allImportedDeviceFilenames() -> Set<String> {
        let existingNames = Set(LibraryFileDiscovery.files(in: baseDirectory, suffix: ".mp3").map(\.logicalName))
        return Set(meta.compactMap { filename, value in
            existingNames.contains(filename) ? value.deviceFilename : nil
        })
    }

    /// Check if a device filename has been imported (even if later renamed).
    public func isImported(deviceFilename: String) -> Bool {
        let mp3Name = deviceFilename.hasSuffix(".hda")
            ? deviceFilename.replacingOccurrences(of: ".hda", with: ".mp3")
            : deviceFilename
        let matchingKeys = Set(meta.compactMap { key, value in
            key == mp3Name || value.deviceFilename == deviceFilename ? key : nil
        })
        guard !matchingKeys.isEmpty else { return false }
        // Metadata annotates canonical files; a stale entry is not an import.
        return LibraryFileDiscovery.files(in: baseDirectory, suffix: ".mp3").contains {
            matchingKeys.contains($0.logicalName)
        }
    }

    /// Update library.json when a recording is renamed.
    public func renameMeta(from oldFilename: String, to newFilename: String) {
        let oldKey = (oldFilename as NSString).lastPathComponent
        let newKey = (newFilename as NSString).lastPathComponent
        if let m = meta.removeValue(forKey: oldKey) {
            meta[newKey] = m
            saveLibraryMeta()
        }
    }

    /// Remove a metadata entry when a recording is deleted.
    public func removeMeta(for filename: String) {
        let key = (filename as NSString).lastPathComponent
        meta.removeValue(forKey: key)
        saveLibraryMeta()
    }

    /// Reject orphan sidecars too, before moving audio or replacing metadata.
    private func requireAvailableRecordingPath(_ filename: String) throws {
        let stem = (filename as NSString).deletingPathExtension
        for name in [filename, stem + ".transcript.json", stem + ".summary.json", stem + ".txt"] {
            let url = baseDirectory.appendingPathComponent(name)
            let placeholder = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
            if FileManager.default.fileExists(atPath: url.path) || FileManager.default.fileExists(atPath: placeholder.path) {
                throw HiDockError.invalidFilename(filename)
            }
        }
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

    /// Check if a recording has already been downloaded (even if later renamed).
    /// Accepts either HDA or MP3 filename — converts HDA to MP3 for the check.
    public func isDownloaded(filename: String) -> Bool {
        let mp3Name = filename.hasSuffix(".hda")
            ? filename.replacingOccurrences(of: ".hda", with: ".mp3")
            : filename
        // Direct file check (fast path for un-renamed recordings)
        let url = baseDirectory.appendingPathComponent(mp3Name)
        if FileManager.default.fileExists(atPath: url.path) { return true }
        let placeholder = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).icloud")
        if FileManager.default.fileExists(atPath: placeholder.path) { return true }
        // Check library.json for renamed recordings
        return isImported(deviceFilename: filename)
    }
}
