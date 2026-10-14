// © 2026 High Gain Design. All rights reserved.
import Foundation

/// Locale/time-zone independent companion bytes. JSON retains unknown fields
/// from its selected generation; Markdown/TXT are derived, never edit authority.
public enum SharedLibraryReadableExport {
    public static func files(view: SharedLibraryViewSnapshot, recordingPath: String) throws -> [String: Data] {
        _ = try SharedLibraryIdentity.normalized(recordingPath)
        guard view.state.kind == .recording else { throw SharedSidecarError.invalidContent }
        let stem = (recordingPath as NSString).deletingPathExtension
        var result: [String: Data] = [:]
        if let transcript = try SharedSidecarAdapter.transcript(view, filename: recordingPath),
           let state = try SharedSidecarAdapter.content(view, component: .transcript),
           let generation = state.currentDocument(for: .transcript) {
            guard transcript.segments.allSatisfy({ $0.startTime.isFinite && $0.endTime.isFinite && $0.startTime >= 0
                && $0.endTime >= $0.startTime && $0.endTime <= Double(Int32.max) }) else { throw SharedSidecarError.invalidContent }
            var body = try object(generation.json)
            body["recordingFilename"] = recordingPath
            body["speakerNames"] = transcript.speakerNames
            let bytes = try SharedProjectionDocument.make(body: body, libraryID: view.libraryID, entities: [view.state.id],
                kind: "transcript", generation: generation.id, revision: view.fingerprint, hasConflicts: !view.state.conflicts.isEmpty)
            result[stem + ".transcript.json"] = bytes
            let header = try banner(bytes)
            var lines = [header, "# Transcript", "", "*\(iso(transcript.createdAt))*", ""]
            var previous: String?
            for segment in transcript.segments {
                let speaker = segment.speakerID.map { transcript.speakerNames[$0] ?? $0 } ?? "Unknown"
                if speaker != previous { lines += ["## " + oneLine(speaker), ""]; previous = speaker }
                lines += ["**[\(timestamp(segment.startTime))]** \(segment.text)", ""]
            }
            result[stem + ".transcript.md"] = Data(lines.joined(separator: "\n").utf8)
            result[stem + ".txt"] = Data(TranscriptExporter.exportPlainText(transcript: transcript).utf8)
        }
        if let summary = try SharedSidecarAdapter.summary(view, filename: recordingPath),
           let state = try SharedSidecarAdapter.content(view, component: .summary),
           let generation = state.currentDocument(for: .summary) {
            var body = try object(generation.json)
            body["recordingFilename"] = recordingPath
            let items = summary.sections.flatMap { $0.items ?? [] }
            guard Set(items.map(\.id)).count == items.count else { throw SharedSidecarError.invalidContent }
            let completion = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.isCompleted) })
            if var sections = body["sections"] as? [[String: Any]] {
                for index in sections.indices {
                    if var items = sections[index]["items"] as? [[String: Any]] {
                        for item in items.indices {
                            if let text = items[item]["id"] as? String, let id = UUID(uuidString: text), let done = completion[id] {
                                items[item]["isCompleted"] = done
                            }
                        }
                        sections[index]["items"] = items
                    }
                }
                body["sections"] = sections
            }
            let bytes = try SharedProjectionDocument.make(body: body, libraryID: view.libraryID, entities: [view.state.id],
                kind: "summary", generation: generation.id, revision: view.fingerprint, hasConflicts: !view.state.conflicts.isEmpty)
            result[stem + ".summary.json"] = bytes
            var lines = [try banner(bytes), "# Summary", "", "*\(iso(summary.createdAt))*", ""]
            for section in summary.sections {
                lines += ["## " + oneLine(section.heading), "", section.content, ""]
                for item in section.items ?? [] { lines.append("- [\(item.isCompleted ? "x" : " ")] \(oneLine(item.text))") }
                if section.items != nil { lines.append("") }
            }
            result[stem + ".summary.md"] = Data(lines.joined(separator: "\n").utf8)
        }
        return result
    }
    private static func object(_ bytes: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw SharedSidecarError.invalidContent }
        return object
    }
    private static func banner(_ bytes: Data) throws -> String {
        guard let marker = try SharedProjectionDocument.marker(in: bytes) else { throw SharedSidecarError.invalidContent }
        return "<!-- DockTape generated; revision \(marker.revision); content \(marker.bodyFingerprint); conflicts \(marker.hasConflicts) -->"
    }
    private static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    private static func oneLine(_ text: String) -> String { text.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ") }
    private static func timestamp(_ time: Double) -> String {
        guard time.isFinite else { return "00:00" }
        let seconds = Int(max(0, min(Double(Int32.max), time)))
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }
}
