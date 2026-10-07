// © 2026 High Gain Design. All rights reserved.

// Sources/HiDockKit/Summarization/SummaryStore.swift
import Foundation

/// Persists summaries as JSON files alongside recordings.
/// Each summary is stored as `{recording_basename}.summary.json`.
public actor SummaryStore {
    private let baseDirectory: URL
    private var cache: [String: Summary] = [:]  // keyed by MP3 filename

    public init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
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
    private func loadFromDisk(mp3Filename: String) -> Summary? {
        let url = fileURL(for: mp3Filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Summary.self, from: data)
    }

    /// Save a summary, keyed by MP3 filename.
    public func save(_ summary: Summary, mp3Filename: String) throws {
        let url = fileURL(for: mp3Filename)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(summary)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        cache[mp3Filename] = summary
        knownFiles.insert(mp3Filename)
    }

    /// Get a summary for a recording (lazy-loads from disk).
    public func summary(for mp3Filename: String) -> Summary? {
        if let cached = cache[mp3Filename] { return cached }
        if let loaded = loadFromDisk(mp3Filename: mp3Filename) {
            cache[mp3Filename] = loaded
            return loaded
        }
        return nil
    }

    /// Check if a summary exists (fast, no parsing).
    public func hasSummary(for mp3Filename: String) -> Bool {
        cache[mp3Filename] != nil || knownFiles.contains(mp3Filename)
    }

    /// Toggle an action item's completion state and persist.
    public func toggleItem(_ itemID: UUID, inSummaryFor mp3Filename: String) throws {
        guard var summary = cache[mp3Filename] else { return }
        for sectionIndex in summary.sections.indices {
            guard var items = summary.sections[sectionIndex].items else { continue }
            if let itemIndex = items.firstIndex(where: { $0.id == itemID }) {
                items[itemIndex].isCompleted.toggle()
                summary.sections[sectionIndex] = Summary.Section(
                    id: summary.sections[sectionIndex].id,
                    heading: summary.sections[sectionIndex].heading,
                    content: summary.sections[sectionIndex].content,
                    items: items
                )
                try save(summary, mp3Filename: mp3Filename)
                return
            }
        }
    }

    /// Delete a summary.
    public func delete(for mp3Filename: String) throws {
        let url = fileURL(for: mp3Filename)
        try? FileManager.default.removeItem(at: url)
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
    public func rename(from oldMp3: String, to newMp3: String) throws {
        guard let oldSummary = cache[oldMp3]
            ?? loadFromDisk(mp3Filename: newMp3)
            ?? loadFromDisk(mp3Filename: oldMp3) else { return }
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
        try save(updated, mp3Filename: newMp3)
        if oldMp3 != newMp3 {
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
