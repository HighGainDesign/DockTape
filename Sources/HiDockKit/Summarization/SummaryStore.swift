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

    /// Load all summaries from disk (recursively, including subfolders).
    public func loadAll() throws {
        cache.removeAll()
        let fm = FileManager.default
        guard fm.fileExists(atPath: baseDirectory.path) else { return }

        guard let enumerator = fm.enumerator(
            at: baseDirectory,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return }

        let basePath = baseDirectory.resolvingSymlinksInPath().path
        let basePrefix = basePath.hasSuffix("/") ? basePath : basePath + "/"

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for case let file as URL in enumerator {
            guard file.pathExtension == "json",
                  file.lastPathComponent.contains(".summary.") else { continue }
            do {
                let data = try Data(contentsOf: file)
                let summary = try decoder.decode(Summary.self, from: data)
                let resolvedPath = file.resolvingSymlinksInPath().path
                let relativePath = resolvedPath.hasPrefix(basePrefix)
                    ? String(resolvedPath.dropFirst(basePrefix.count))
                    : file.lastPathComponent
                let mp3Key = relativePath.replacingOccurrences(of: ".summary.json", with: ".mp3")
                cache[mp3Key] = summary
            } catch {
                continue  // skip corrupt files
            }
        }
    }

    /// Save a summary, keyed by MP3 filename.
    public func save(_ summary: Summary, mp3Filename: String) throws {
        let url = fileURL(for: mp3Filename)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(summary)
        try data.write(to: url)
        cache[mp3Filename] = summary
    }

    /// Get a summary for a recording.
    public func summary(for mp3Filename: String) -> Summary? {
        cache[mp3Filename]
    }

    /// Check if a summary exists.
    public func hasSummary(for mp3Filename: String) -> Bool {
        cache[mp3Filename] != nil
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
    }

    /// All cached summaries.
    public func allSummaries() -> [Summary] {
        Array(cache.values)
    }

    /// Re-key a summary after recording rename.
    public func rename(from oldMp3: String, to newMp3: String) {
        guard let summary = cache.removeValue(forKey: oldMp3) else { return }
        cache[newMp3] = summary
    }

    private func fileURL(for mp3Filename: String) -> URL {
        let basename = (mp3Filename as NSString).deletingPathExtension
        return baseDirectory.appendingPathComponent("\(basename).summary.json")
    }
}
