// © 2026 High Gain Design. All rights reserved.

import Foundation

/// Converts .hda files to .mp3 by stripping the proprietary header.
///
/// .hda files are MP3 audio with a prepended header. We scan for the MP3
/// sync word (0xFF 0xFB or 0xFF 0xF3) and copy everything from there.
public enum HDAConverter {

    /// Extract MP3 data from an .hda file's raw bytes.
    /// Returns nil if no MP3 sync word is found.
    public static func extractMP3(from hdaData: Data) -> Data? {
        guard hdaData.count > 2 else { return nil }

        // Scan for MP3 frame sync: 0xFF followed by 0xFB or 0xF3
        // (MPEG1 Layer3 or MPEG2 Layer3)
        for i in 0 ..< hdaData.count - 1 {
            let byte0 = hdaData[hdaData.startIndex + i]
            let byte1 = hdaData[hdaData.startIndex + i + 1]
            if byte0 == 0xFF && (byte1 == 0xFB || byte1 == 0xF3) {
                return hdaData.subdata(in: (hdaData.startIndex + i) ..< hdaData.endIndex)
            }
        }

        return nil
    }

    /// Convert .hda data and write the resulting .mp3 to a file.
    /// - Returns: The URL of the written file.
    @discardableResult
    public static func convertAndWrite(hdaData: Data, to outputURL: URL) throws -> URL {
        guard let mp3Data = extractMP3(from: hdaData) else {
            throw HiDockError.conversionFailed("No MP3 sync word found in .hda data")
        }
        try mp3Data.write(to: outputURL)
        return outputURL
    }
}
