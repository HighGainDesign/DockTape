// © 2026 High Gain Design. All rights reserved.

import Foundation

/// Metadata for a recording, derived entirely from the MP3 file on disk.
/// No persistence — the filesystem is the source of truth.
public struct RecordingMetadata: Sendable, Identifiable {
    public var id: String { reference.map { $0.libraryID.uuidString + ":" + $0.entityID.uuidString } ?? filename }
    public let reference: SharedRecordingReference?

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

    /// Folder this recording lives in (relative to library root), or nil for root.
    public let folder: String?

    public init(
        filename: String,
        recordedAt: Date?,
        mode: String,
        fileSizeBytes: UInt64,
        estimatedDuration: TimeInterval,
        folder: String? = nil,
        reference: SharedRecordingReference? = nil
    ) {
        self.reference = reference
        self.filename = filename
        self.recordedAt = recordedAt
        self.mode = mode
        self.fileSizeBytes = fileSizeBytes
        self.estimatedDuration = estimatedDuration
        self.folder = folder
    }

    public func retargeted(to filename: String) -> RecordingMetadata {
        let folder = (filename as NSString).deletingLastPathComponent
        return .init(filename: filename, recordedAt: recordedAt, mode: mode, fileSizeBytes: fileSizeBytes,
                     estimatedDuration: estimatedDuration, folder: folder.isEmpty ? nil : folder, reference: reference)
    }

    /// Display title: formatted date if the filename is still in device format, otherwise the user's chosen name.
    public var displayTitle: String {
        let basename = (filename as NSString).lastPathComponent
        let parsed = FilenameParsing.parse(basename)
        if parsed.mode != .unknown, let date = parsed.date {
            return Self.displayFormatter.string(from: date)
        }
        return (basename as NSString).deletingPathExtension
    }

    private static let displayFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return fmt
    }()
}
