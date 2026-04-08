import Foundation

/// Metadata for a recording, derived entirely from the MP3 file on disk.
/// No persistence — the filesystem is the source of truth.
public struct RecordingMetadata: Sendable, Identifiable {
    public var id: String { filename }

    /// MP3 filename on disk (e.g., "REC_20240315_143000.mp3" or "Meeting with Bob.mp3").
    public let filename: String

    /// When the recording was made, parsed from filename (falls back to file creation date).
    public let recordedAt: Date?

    /// Recording mode parsed from filename (Rec, Pho, Mee, Wip), or empty if not parseable.
    public let mode: String

    /// MP3 file size in bytes.
    public let fileSizeBytes: UInt64

    /// Estimated duration from MP3 file size.
    public let estimatedDuration: TimeInterval

    public init(
        filename: String,
        recordedAt: Date?,
        mode: String,
        fileSizeBytes: UInt64,
        estimatedDuration: TimeInterval
    ) {
        self.filename = filename
        self.recordedAt = recordedAt
        self.mode = mode
        self.fileSizeBytes = fileSizeBytes
        self.estimatedDuration = estimatedDuration
    }

    /// Display title: formatted date if the filename parses as a device name, otherwise filename without extension.
    public var displayTitle: String {
        if let date = recordedAt, !mode.isEmpty {
            let fmt = DateFormatter()
            fmt.dateStyle = .medium
            fmt.timeStyle = .short
            return fmt.string(from: date)
        }
        return (filename as NSString).deletingPathExtension
    }
}
