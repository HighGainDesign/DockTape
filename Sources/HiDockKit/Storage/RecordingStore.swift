// © 2026 High Gain Design. All rights reserved.

import Foundation
import CryptoKit

/// Manages local storage of downloaded recordings.
/// Audio files are canonical; library.json preserves metadata through renames.
public actor RecordingStore {
    public nonisolated let baseDirectory: URL
    private let fileAccess: RecordingFileAccess
    private let metadataFileAccess: RecordingFileAccess
    private let shared: SharedRecordingMetadataAdapter?

    public init(baseDirectory: URL? = nil, fileAccess: RecordingFileAccess = RecordingFileAccess(),
                metadataFileAccess: RecordingFileAccess = RecordingFileAccess(),
                shared: SharedRecordingMetadataAdapter? = nil) {
        self.fileAccess = fileAccess
        self.metadataFileAccess = metadataFileAccess
        self.shared = shared
        if let dir = baseDirectory {
            self.baseDirectory = dir
        } else {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            self.baseDirectory = docs.appendingPathComponent("HiDock Recordings")
        }
    }

    /// Ensure the storage directory exists and load persisted metadata.
    public func setup() async throws {
        try shared?.requireRoot(baseDirectory)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        try await loadLibraryMeta()
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
    public func createFolder(named name: String) async throws {
        if let shared { try shared.requireRoot(baseDirectory); try await shared.coordinator.createSharedFolder(named: Self.sanitizeFilename(name)); return }
        try LegacyLibraryFileAccess.requireLegacyRoot(baseDirectory)
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
        try LegacyLibraryFileAccess.requireLegacyRoot(baseDirectory)
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
        try LegacyLibraryFileAccess.requireLegacyRoot(baseDirectory)
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
    public func moveRecording(filename: String, toFolder folderName: String?) async throws -> String {
        if let shared {
            try shared.requireRoot(baseDirectory)
            metadataTicket += 1
            let outcome = try await shared.coordinator.relocateRecording(filename: filename, toFolder: folderName, changeFolder: true)
            return try cacheSharedRelocation(outcome, from: filename)
        }
        try LegacyLibraryFileAccess.requireLegacyRoot(baseDirectory)
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
            let recordMeta = meta[metadataKey(for: relativePath)]
            let originalDate = recordMeta?.deviceFilename.flatMap { FilenameParsing.parse($0).date }
            let recordedAt = recordMeta?.recordedAt ?? parsed.date ?? originalDate ?? attrs.creationDate
            let mode: String
            if parsed.mode != .unknown {
                mode = parsed.mode.rawValue
            } else {
                mode = recordMeta?.mode ?? ""
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

    /// Store imported audio, preserving the existing path when repairing it.
    @discardableResult
    public func storeRecording(hdaData: Data, entry: FileEntry) async throws -> RecordingMetadata {
        if let imported = try await importRecording(hdaData: hdaData, entry: entry) {
            return imported
        }
        guard let existing = try existingRecording(for: entry) else {
            throw HiDockError.fileNotFound(entry.filename)
        }
        return existing
    }

    /// Skip a transfer only when both the device source and saved audio are verified.
    /// An absent/unproven device checksum or legacy metadata needs byte comparison.
    public func matchesVerifiedImport(_ entry: FileEntry) async throws -> Bool {
        guard let existing = try existingRecording(for: entry) else { return false }
        let key = metadataKey(for: existing.filename)
        guard let saved = meta[key], let sourceMD5 = saved.sourceMD5,
              sourceMD5 == entry.md5.lowercased(), let audioSHA256 = saved.audioSHA256 else {
            return false
        }
        let url = baseDirectory.appendingPathComponent(existing.filename)
        guard let bytes = try await fileAccess.readDataIfPresent(at: url, knownToExist: true) else {
            return false
        }
        // A rename/move or a new import during cloud hydration invalidates this check.
        guard try existingRecording(for: entry)?.filename == existing.filename,
              meta[key]?.sourceMD5 == sourceMD5, meta[key]?.audioSHA256 == audioSHA256 else {
            return false
        }
        return Self.sha256(bytes) == audioSHA256
    }

    /// Returns nil for identical audio. Different bytes repair the existing file
    /// atomically, with no retained backup/copy; sidecars stay available for review.
    public func importRecording(hdaData: Data, entry: FileEntry) async throws -> RecordingMetadata? {
        try LegacyLibraryFileAccess.requireLegacyRoot(baseDirectory)
        guard hdaData.count == Int(entry.size) else {
            throw HiDockError.transferFailed("The recording transfer was incomplete. Existing audio was left unchanged.")
        }
        guard let mp3Data = HDAConverter.extractMP3(from: hdaData) else {
            throw HiDockError.conversionFailed("No MP3 sync word found in .hda data")
        }
        let existing = try existingRecording(for: entry)
        let filename = existing?.filename ?? entry.filename.replacingOccurrences(
            of: ".hda", with: ".mp3", options: .caseInsensitive)
        let key = metadataKey(for: filename)
        let previous = meta[key]
        let rawMD5 = Insecure.MD5.hash(data: hdaData).map { String(format: "%02x", $0) }.joined()
        let audioSHA256 = Self.sha256(mp3Data)
        let reportedMD5 = entry.md5.lowercased()
        // The old raw baseline proves this exact source fingerprint. A changed
        // source/format can have different checksum coverage; compare its bytes
        // and establish a fresh baseline rather than rejecting a valid re-import.
        if previous?.sourceMD5 == reportedMD5, reportedMD5.count == 32,
           reportedMD5 != String(repeating: "0", count: 32),
           reportedMD5.allSatisfy({ $0.isHexDigit }), rawMD5 != reportedMD5,
           previous?.audioSHA256 != audioSHA256 {
            throw HiDockError.transferFailed("The downloaded recording failed its device checksum. Existing audio was left unchanged.")
        }
        let outputURL = baseDirectory.appendingPathComponent(filename)
        var unchanged = false
        if existing != nil {
            let bytes = try await fileAccess.readDataIfPresent(at: outputURL, knownToExist: true)
            try Task.checkCancellation()
            guard try existingRecording(for: entry)?.filename == filename, meta[key] == previous else {
                throw HiDockError.storageError("The library changed while checking this recording. Try importing again.")
            }
            unchanged = bytes == mp3Data
        } else {
            // Do not attach unrelated orphan sidecars to a new recording.
            try requireAvailableRecordingPath(filename)
        }
        try Task.checkCancellation()
        if !unchanged { try mp3Data.write(to: outputURL, options: .atomic) }

        let parsed = FilenameParsing.parse(key)
        let mode = previous?.mode ?? (parsed.mode == .unknown ? nil : parsed.mode.rawValue)
        let recordedAt = previous?.recordedAt ?? existing?.recordedAt ?? parsed.date
            ?? (try? outputURL.resourceValues(forKeys: [.creationDateKey]))?.creationDate
        var updated = previous ?? RecordingMeta(mode: mode, deviceFilename: entry.filename, recordedAt: recordedAt)
        updated.mode = mode
        updated.deviceFilename = entry.filename
        updated.recordedAt = recordedAt
        updated.sourceMD5 = rawMD5 == reportedMD5 ? rawMD5 : nil
        updated.audioSHA256 = audioSHA256
        if previous != updated {
            meta[key] = updated
            try await saveLibraryMeta()
        }
        if unchanged { return nil }
        let folderPath = (filename as NSString).deletingLastPathComponent
        return RecordingMetadata(
            filename: filename,
            recordedAt: recordedAt,
            mode: mode ?? "",
            fileSizeBytes: UInt64(mp3Data.count),
            estimatedDuration: DurationCalculator.estimateDuration(fileSize: UInt64(mp3Data.count)),
            folder: folderPath.isEmpty || folderPath == "." ? nil : folderPath
        )
    }

    private static func sha256(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private func existingRecording(for entry: FileEntry) throws -> RecordingMetadata? {
        let mp3Name = entry.filename.replacingOccurrences(of: ".hda", with: ".mp3", options: .caseInsensitive)
        let matches = allRecordings().filter { recording in
            let key = metadataKey(for: recording.filename)
            return (recording.filename as NSString).lastPathComponent == mp3Name || meta[key]?.deviceFilename == entry.filename
        }
        let uniquePaths = Set(matches.map(\.filename))
        guard uniquePaths.count <= 1 else {
            throw HiDockError.storageError("Multiple library recordings match this device file. Resolve the duplicates before importing again.")
        }
        return matches.first
    }

    // MARK: - Merge recordings

    /// Merge encoded audio frames, rebuilding duration metadata without re-encoding.
    /// Files are concatenated in the order provided. Returns metadata for the merged recording.
    @discardableResult
    public func mergeRecordings(filenames: [String], as newFilename: String) async throws -> RecordingMetadata {
        try LegacyLibraryFileAccess.requireLegacyRoot(baseDirectory)
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
        meta[outputFilename] = metaEntry
        try await saveLibraryMeta()

        return RecordingMetadata(
            filename: outputFilename,
            recordedAt: earliestDate,
            mode: firstMode,
            fileSizeBytes: fileSize,
            estimatedDuration: DurationCalculator.estimateDuration(fileSize: fileSize)
        )
    }

    /// Delete a local recording and all its sidecars.
    public func deleteRecordingAndSidecars(filename: String) async throws {
        if let shared {
            try shared.requireRoot(baseDirectory)
            metadataTicket += 1
            let outcome = try await shared.coordinator.deleteSharedRecording(filename: filename)
            sharedOperation = outcome
            guard outcome.result == .complete else { throw SharedLibraryOperationError.unfinishedOperation }
            meta.removeValue(forKey: filename); metaBaseline.removeValue(forKey: filename)
            return
        }
        try LegacyLibraryFileAccess.requireLegacyRoot(baseDirectory)
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
        try await removeMeta(for: filename)
    }

    /// Delete a local recording and its plain-text sidecar.
    public func deleteRecording(filename: String) async throws {
        if shared != nil { try await deleteRecordingAndSidecars(filename: filename); return }
        try LegacyLibraryFileAccess.requireLegacyRoot(baseDirectory)
        let url = baseDirectory.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: url)

        // Remove .txt sidecar (best effort)
        let basename = (filename as NSString).deletingPathExtension
        let txtURL = baseDirectory.appendingPathComponent("\(basename).txt")
        try? FileManager.default.removeItem(at: txtURL)

        try await removeMeta(for: filename)
    }

    /// Rename a recording file on disk, plus the associated transcript file.
    /// Returns the new filename.
    @discardableResult
    public func renameRecording(filename: String, to newName: String) async throws -> String {
        if let shared {
            try shared.requireRoot(baseDirectory)
            let title = Self.sanitizeFilename(newName.hasSuffix(".mp3") ? String(newName.dropLast(4)) : newName)
            guard !title.isEmpty else { throw HiDockError.invalidFilename(newName) }
            metadataTicket += 1
            let outcome = try await shared.coordinator.relocateRecording(filename: filename, title: title)
            return try cacheSharedRelocation(outcome, from: filename)
        }
        try LegacyLibraryFileAccess.requireLegacyRoot(baseDirectory)
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

        let oldKey = metadataKey(for: filename)
        let originalBasename = (filename as NSString).lastPathComponent
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

        if meta[oldKey] == nil {
            let parsed = FilenameParsing.parse(originalBasename)
            meta[oldKey] = RecordingMeta(
                mode: parsed.mode == .unknown ? nil : parsed.mode.rawValue,
                deviceFilename: parsed.date == nil ? nil : (originalBasename as NSString).deletingPathExtension + ".hda",
                recordedAt: parsed.date ?? (try? newURL.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            )
        }
        if meta[oldKey]?.deviceFilename == nil, FilenameParsing.parse(originalBasename).date != nil {
            meta[oldKey]?.deviceFilename = (originalBasename as NSString).deletingPathExtension + ".hda"
        }
        try await renameMeta(from: oldKey, to: newFilename)
        return newFilename
    }

    /// Get the file URL for a recording's MP3.
    public func mp3URL(for metadata: RecordingMetadata) -> URL {
        baseDirectory.appendingPathComponent(metadata.filename)
    }

    public private(set) var sharedOperation: SharedRecordingFileOutcome?
    private func cacheSharedRelocation(_ outcome: SharedRecordingFileOutcome, from previous: String) throws -> String {
        sharedOperation = outcome
        guard outcome.result == .complete else { throw SharedLibraryOperationError.unfinishedOperation }
        let accepted = try SharedRecordingMetadataAdapter.render(outcome.view)
        meta.removeValue(forKey: previous); metaBaseline.removeValue(forKey: previous)
        meta[outcome.filename] = accepted; metaBaseline[outcome.filename] = accepted
        return outcome.filename
    }

    // MARK: - Recording metadata (library.json)

    /// Per-recording metadata that survives renames. Keyed by current filename.
    public struct RecordingMeta: Codable, Equatable, Sendable {
        public var mode: String?
        public var deviceFilename: String?
        public var mergedFrom: [String]?
        public var recordedAt: Date?
        /// Verified raw HDA fingerprint, only when it matched the device field.
        public var sourceMD5: String?
        /// Imported MP3 baseline used to detect later corruption.
        public var audioSHA256: String?
    }

    /// In-memory cache of filename → metadata.
    private var meta: [String: RecordingMeta] = [:]
    private var metaBaseline: [String: RecordingMeta] = [:]
    private var metadataTicket: UInt64 = 0

    /// Load library.json from disk. Also migrates modes.json if present.
    public func loadLibraryMeta() async throws {
        if let shared {
            try shared.requireRoot(baseDirectory)
            metadataTicket += 1; let ticket = metadataTicket
            let loaded = try await shared.load()
            if metadataTicket == ticket { meta = loaded; metaBaseline = loaded }
            return
        }
        let url = baseDirectory.appendingPathComponent("library.json")
        metadataTicket += 1
        let ticket = metadataTicket
        let bytes = try await metadataFileAccess.readDataIfPresent(at: url)
        let loaded = try bytes.map { try JSONDecoder().decode([String: RecordingMeta].self, from: $0) } ?? [:]
        guard metadataTicket == ticket else { return }
        meta = loaded; metaBaseline = loaded
        let modesURL = baseDirectory.appendingPathComponent("modes.json")
        if let modes = try await metadataFileAccess.readDataIfPresent(at: modesURL) {
            let dict = try JSONDecoder().decode([String: String].self, from: modes)
            for (key, mode) in dict where meta[key]?.mode == nil {
                var item = meta[key] ?? RecordingMeta()
                item.mode = mode; meta[key] = item
            }
            try await saveLibraryMeta()
            try FileManager.default.removeItem(at: modesURL)
        }
    }

    /// Only changed fields/paths enter the coordinated read-modify-write. Raw
    /// unknown fields and unrelated edits from another local store stay intact.
    private func saveLibraryMeta() async throws {
        if let shared {
            try shared.requireRoot(baseDirectory)
            metadataTicket += 1
            let changes = Set(meta.keys).union(metaBaseline.keys).sorted().filter { meta[$0] != metaBaseline[$0] }
            do {
                for key in changes {
                    guard let desired = meta[key] else { throw SharedSidecarError.invalidContent }
                    let accepted = try await shared.save(filename: key, before: metaBaseline[key], after: desired)
                    meta[key] = accepted; metaBaseline[key] = accepted
                }
            } catch {
                meta = metaBaseline
                throw error
            }
            return
        }
        struct Change: Sendable { let key: String; let before: Data?; let after: Data? }
        let encoder = JSONEncoder()
        let changes = try Set(meta.keys).union(metaBaseline.keys).sorted().compactMap { key -> Change? in
            guard meta[key] != metaBaseline[key] else { return nil }
            _ = try SharedLibraryIdentity.normalized(key)
            return Change(key: key, before: try metaBaseline[key].map(encoder.encode), after: try meta[key].map(encoder.encode))
        }
        if changes.isEmpty { return }
        metadataTicket += 1; let ticket = metadataTicket
        let bytes = try await LegacyLibraryFileAccess().mutateObject(
            at: baseDirectory.appendingPathComponent("library.json"), root: baseDirectory) { object in
                _ = try JSONDecoder().decode([String: RecordingMeta].self, from: JSONSerialization.data(withJSONObject: object))
                for change in changes {
                    guard let after = change.after else { object.removeValue(forKey: change.key); continue }
                    let desired = try JSONSerialization.jsonObject(with: after) as! [String: Any]
                    let before = try change.before.map { try JSONSerialization.jsonObject(with: $0) as! [String: Any] } ?? [:]
                    var current = object[change.key] as? [String: Any] ?? [:]
                    for field in Set(desired.keys).union(before.keys) {
                        let old = try before[field].map { try JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed, .sortedKeys]) }
                        let new = try desired[field].map { try JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed, .sortedKeys]) }
                        if old != new { current[field] = desired[field] }
                    }
                    object[change.key] = current
                }
            }
        let loaded = try JSONDecoder().decode([String: RecordingMeta].self, from: bytes)
        if metadataTicket == ticket { meta = loaded; metaBaseline = loaded }
    }

    private func metadataKey(for filename: String) -> String {
        if meta[filename] != nil { return filename }
        let basename = (filename as NSString).lastPathComponent
        guard meta[basename] != nil else { return filename }
        let matches = LibraryFileDiscovery.files(in: baseDirectory, suffix: ".mp3").filter { $0.logicalName == basename }
        return matches.count == 1 && matches[0].relativePath == filename ? basename : filename
    }

    /// Record metadata for a downloaded file. Call after storeRecording.
    public func setMeta(mode: String, deviceFilename: String, for filename: String) async throws {
        let key = try SharedLibraryIdentity.normalized(filename)
        var item = meta[key] ?? meta[metadataKey(for: filename)] ?? RecordingMeta()
        item.mode = mode.isEmpty ? nil : mode; item.deviceFilename = deviceFilename
        meta[key] = item
        try await saveLibraryMeta()
    }

    /// Look up the persisted mode for a filename.
    public func mode(for filename: String) -> String? {
        return meta[metadataKey(for: filename)]?.mode
    }

    /// All device filenames that have been imported (for synchronous download checks).
    public func allImportedDeviceFilenames() -> Set<String> {
        let files = LibraryFileDiscovery.files(in: baseDirectory, suffix: ".mp3")
        let paths = Set(files.map(\.relativePath))
        return Set(meta.compactMap { key, value in
            let unambiguousLegacy = !key.contains("/") && files.filter { $0.logicalName == key }.count == 1
            return paths.contains(key) || unambiguousLegacy ? value.deviceFilename : nil
        })
    }

    public func isImported(deviceFilename: String) -> Bool {
        let mp3Name = deviceFilename.hasSuffix(".hda")
            ? deviceFilename.replacingOccurrences(of: ".hda", with: ".mp3") : deviceFilename
        let keys = Set(meta.compactMap { key, value in
            (key as NSString).lastPathComponent == mp3Name || value.deviceFilename == deviceFilename ? key : nil
        })
        let files = LibraryFileDiscovery.files(in: baseDirectory, suffix: ".mp3")
        return files.contains { file in
            keys.contains(file.relativePath) || (keys.contains(file.logicalName)
                && files.filter { $0.logicalName == file.logicalName }.count == 1)
        }
    }

    /// Update library.json when a recording is renamed.
    public func renameMeta(from oldFilename: String, to newFilename: String) async throws {
        guard shared == nil else { throw SharedSidecarError.invalidContent }
        let oldKey = metadataKey(for: oldFilename)
        let newKey = try SharedLibraryIdentity.normalized(newFilename)
        if let m = meta.removeValue(forKey: oldKey) {
            meta[newKey] = m
            try await saveLibraryMeta()
        }
    }

    /// Remove a metadata entry when a recording is deleted.
    public func removeMeta(for filename: String) async throws {
        guard shared == nil else { throw SharedSidecarError.invalidContent }
        let key = metadataKey(for: filename)
        meta.removeValue(forKey: key)
        try await saveLibraryMeta()
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
