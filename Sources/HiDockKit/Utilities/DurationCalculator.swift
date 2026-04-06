import Foundation

/// Estimates recording duration from file size and encoding parameters.
///
/// HiDock records MP3 at known bitrates:
/// - P1/P1 Mini: 128 kbps
/// - H1/H1E: 128 kbps (default), can vary
public enum DurationCalculator {

    /// Standard bitrate in bits per second.
    public static let defaultBitrate: Int = 128_000

    /// Estimate duration in seconds from file size.
    /// - Parameters:
    ///   - fileSize: Size of the .hda/.mp3 file in bytes.
    ///   - bitrate: Encoding bitrate in bits per second (default: 128 kbps).
    /// - Returns: Estimated duration in seconds.
    public static func estimateDuration(fileSize: UInt64, bitrate: Int = defaultBitrate) -> TimeInterval {
        guard bitrate > 0, fileSize > 0 else { return 0 }
        return TimeInterval(fileSize) * 8.0 / TimeInterval(bitrate)
    }

    /// Format a duration in seconds to "HH:MM:SS" or "MM:SS".
    public static func formatDuration(_ seconds: TimeInterval) -> String {
        let totalSeconds = Int(seconds)
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60

        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        } else {
            return String(format: "%d:%02d", m, s)
        }
    }
}
