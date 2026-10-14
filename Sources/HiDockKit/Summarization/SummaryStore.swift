// © 2026 High Gain Design. All rights reserved.

// Sources/HiDockKit/Summarization/SummaryStore.swift
import Foundation

/// Persists summaries as JSON files alongside recordings.
/// Each summary is stored as `{recording_basename}.summary.json`.
public actor SummaryStore {
    private let baseDirectory: URL
    private let fileAccess: RecordingFileAccess
    private let shared: SharedSidecarAdapter?
    private var revisions: [String: Int] = [:]
    private var cache: [String: Summary] = [:]  // keyed by MP3 filename

    public init(baseDirectory: URL, fileAccess: RecordingFileAccess = RecordingFileAccess(),
                shared: SharedSidecarAdapter? = nil) {
        self.baseDirectory = baseDirectory
        self.fileAccess = fileAccess
        self.shared = shared
    }

    /// Set of MP3 filenames that have summary files on disk.
    private var knownFiles: Set<String> = []

    /// Scan for summary files (existence only, no parsing). Fast startup.
    public func loadAll() throws {
        knownFiles = Set(LibraryFileDiscovery.files(in: baseDirectory, suffix: ".summary.json").map {
            String($0.relativePath.dropLast(".summary.json".count)) + ".mp3"
        })
    }

    /// Load a single summary from disk on demand.
    private func loadFromDisk(mp3Filename: String, knownToExist: Bool = false,
                              onWaiting: @Sendable () async -> Void = {}) async throws -> Summary? {
        let url = fileURL(for: mp3Filename)
        guard let data = try await fileAccess.readDataIfPresent(at: url, knownToExist: knownToExist, onWaiting: onWaiting) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Summary.self, from: data)
    }

    /// Save a summary, keyed by MP3 filename.
    public func save(_ summary: Summary, mp3Filename: String) async throws {
        if let shared {
            try shared.requireRoot(baseDirectory)
            revisions[mp3Filename, default: 0] += 1
            try await shared.save(summary, filename: mp3Filename)
            revisions[mp3Filename, default: 0] += 1
            cache[mp3Filename] = try await shared.summary(for: mp3Filename)
            knownFiles.insert(mp3Filename)
            return
        }
        try LegacyLibraryFileAccess.requireLegacyRoot(baseDirectory)
        let url = fileURL(for: mp3Filename)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(summary)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        revisions[mp3Filename, default: 0] += 1
        cache[mp3Filename] = summary
        knownFiles.insert(mp3Filename)
    }

    /// Get a summary for a recording (lazy-loads from disk).
    public func summary(for mp3Filename: String) async -> Summary? {
        try? await loadSummary(for: mp3Filename)
    }

    /// Throwing UI load distinguishes a missing sidecar from download/read errors.
    public func loadSummary(for mp3Filename: String,
                               onWaiting: @Sendable () async -> Void = {}) async throws -> Summary? {
        let revision = revisions[mp3Filename, default: 0]
        let loaded: Summary?
        if let shared {
            try shared.requireRoot(baseDirectory)
            loaded = try await shared.summary(for: mp3Filename)
        } else {
            loaded = try await loadFromDisk(mp3Filename: mp3Filename,
                                            knownToExist: knownFiles.contains(mp3Filename), onWaiting: onWaiting)
        }
        try Task.checkCancellation()
        guard revisions[mp3Filename, default: 0] == revision else { return cache[mp3Filename] }
        cache[mp3Filename] = loaded
        if loaded != nil { knownFiles.insert(mp3Filename) } else { knownFiles.remove(mp3Filename) }
        return loaded
    }

    /// Check if a summary exists (fast, no parsing).
    public func hasSummary(for mp3Filename: String) -> Bool {
        cache[mp3Filename] != nil || knownFiles.contains(mp3Filename)
    }

    /// Toggle an action item's completion state and persist.
    public func toggleItem(_ itemID: UUID, inSummaryFor mp3Filename: String) async throws {
        if let shared {
            try shared.requireRoot(baseDirectory)
            revisions[mp3Filename, default: 0] += 1
            try await shared.toggleItem(itemID, filename: mp3Filename)
            cache[mp3Filename] = try await shared.summary(for: mp3Filename)
            revisions[mp3Filename, default: 0] += 1
            return
        }
        guard let base = cache[mp3Filename],
              let item = base.sections.flatMap({ $0.items ?? [] }).first(where: { $0.id == itemID }) else {
            throw HiDockError.storageError("Reload this summary before editing.")
        }
        let original = try Self.generationFingerprint(base)
        let desired = !item.isCompleted
        revisions[mp3Filename, default: 0] += 1
        let revision = revisions[mp3Filename, default: 0]
        let bytes = try await LegacyLibraryFileAccess().mutateObject(at: fileURL(for: mp3Filename), root: baseDirectory) { object in
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let current = try decoder.decode(Summary.self, from: JSONSerialization.data(withJSONObject: object))
            guard try Self.generationFingerprint(current) == original else {
                throw HiDockError.storageError("This summary changed while you were editing. Reload it and try again.")
            }
            var sections = object["sections"] as! [[String: Any]]
            var found = false
            for index in sections.indices {
                guard var items = sections[index]["items"] as? [[String: Any]] else { continue }
                for itemIndex in items.indices where (items[itemIndex]["id"] as? String).flatMap(UUID.init(uuidString:)) == itemID {
                    items[itemIndex]["isCompleted"] = desired; found = true
                }
                sections[index]["items"] = items
            }
            guard found else { throw HiDockError.storageError("This action item no longer exists. Reload the summary.") }
            object["sections"] = sections
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let current = try decoder.decode(Summary.self, from: bytes)
        if revisions[mp3Filename, default: 0] == revision { cache[mp3Filename] = current }
    }

    private static func generationFingerprint(_ summary: Summary) throws -> String {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var object = try JSONSerialization.jsonObject(with: encoder.encode(summary)) as! [String: Any]
        object.removeValue(forKey: "recordingFilename")
        var sections = object["sections"] as! [[String: Any]]
        for index in sections.indices {
            guard var items = sections[index]["items"] as? [[String: Any]] else { continue }
            for itemIndex in items.indices { items[itemIndex].removeValue(forKey: "isCompleted") }
            sections[index]["items"] = items
        }
        object["sections"] = sections
        return SharedLibraryOperation.fingerprint(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    }

    /// Delete a summary.
    public func delete(for mp3Filename: String) throws {
        try LegacyLibraryFileAccess.requireLegacyRoot(baseDirectory)
        let url = fileURL(for: mp3Filename)
        try? FileManager.default.removeItem(at: url)
        revisions[mp3Filename, default: 0] += 1
        cache.removeValue(forKey: mp3Filename)
        knownFiles.remove(mp3Filename)
    }

    /// All cached summaries (only those already loaded).
    public func allSummaries() -> [Summary] {
        Array(cache.values)
    }

    /// All MP3 filenames that have summaries (from disk scan, no parsing).
    public func allSummarizedFilenames() -> [String] {
        Array(knownFiles)
    }

    /// Re-key a summary after recording rename, moving the file on disk
    /// and updating the recordingFilename inside the summary.
    public func rename(from oldMp3: String, to newMp3: String) async throws {
        try LegacyLibraryFileAccess.requireLegacyRoot(baseDirectory)
        var loaded = cache[oldMp3]
        if loaded == nil { loaded = try await loadFromDisk(mp3Filename: newMp3) }
        if loaded == nil { loaded = try await loadFromDisk(mp3Filename: oldMp3) }
        guard let oldSummary = loaded else { return }
        let oldURL = fileURL(for: oldMp3)
        let updated = Summary(
            recordingFilename: newMp3,
            createdAt: oldSummary.createdAt,
            model: oldSummary.model,
            provider: oldSummary.provider,
            templateUsed: oldSummary.templateUsed,
            customPrompt: oldSummary.customPrompt,
            sections: oldSummary.sections
        )
        try await save(updated, mp3Filename: newMp3)
        if oldMp3 != newMp3 {
            revisions[oldMp3, default: 0] += 1
            cache.removeValue(forKey: oldMp3)
            knownFiles.remove(oldMp3)
            try? FileManager.default.removeItem(at: oldURL)
        }
    }

    private func fileURL(for mp3Filename: String) -> URL {
        let basename = (mp3Filename as NSString).deletingPathExtension
        return baseDirectory.appendingPathComponent("\(basename).summary.json")
    }
}
