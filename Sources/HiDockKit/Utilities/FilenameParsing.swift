// © 2026 High Gain Design. All rights reserved.

import Foundation

/// Parses HiDock recording filenames to extract date and recording mode.
///
/// Real device filename format: `YYYYMmmDD-HHMMSS-ModeNN.hda`
/// Examples:
///   - `2026Mar30-172146-Rec00.hda` — standard recording
///   - `2026Apr05-005218-Wip02.hda` — WIP/draft recording
///   - `2024Nov15-091500-Pho00.hda` — phone call recording
///   - `2024Nov15-091500-Mee01.hda` — meeting mode recording
///
/// Legacy format (also supported): `REC_YYYYMMDD_HHMMSS.hda`
public enum FilenameParsing {

    public enum RecordingMode: String, Sendable, Codable {
        case standard = "Rec"
        case phone = "Pho"
        case meeting = "Mee"
        case wip = "Wip"
        case unknown = "Unknown"

        public var displayName: String {
            switch self {
            case .standard: return "Recording"
            case .phone: return "Phone Call"
            case .meeting: return "Meeting"
            case .wip: return "WIP"
            case .unknown: return "Unknown"
            }
        }
    }

    public struct ParsedFilename: Sendable {
        public let mode: RecordingMode
        public let date: Date?
        public let originalFilename: String
    }

    /// Parse a HiDock filename into its components.
    public static func parse(_ filename: String) -> ParsedFilename {
        // Try real device format first: YYYYMmmDD-HHMMSS-ModeNN.hda
        if let result = parseDeviceFormat(filename) {
            return result
        }
        // Fall back to legacy format: MODE_YYYYMMDD_HHMMSS.hda
        return parseLegacyFormat(filename)
    }

    // MARK: - Real device format: 2026Mar30-172146-Rec00.hda

    private static let monthNames: [String: Int] = [
        "Jan": 1, "Feb": 2, "Mar": 3, "Apr": 4, "May": 5, "Jun": 6,
        "Jul": 7, "Aug": 8, "Sep": 9, "Oct": 10, "Nov": 11, "Dec": 12
    ]

    private static func parseDeviceFormat(_ filename: String) -> ParsedFilename? {
        let name = (filename as NSString).deletingPathExtension
        let parts = name.split(separator: "-", maxSplits: 2)
        guard parts.count == 3 else { return nil }

        // Part 0: YYYYMmmDD (e.g., "2026Mar30")
        let datePart = String(parts[0])
        guard datePart.count >= 9 else { return nil }
        let yearStr = String(datePart.prefix(4))
        let monthStr = String(datePart.dropFirst(4).prefix(3))
        let dayStr = String(datePart.dropFirst(7))
        guard let year = Int(yearStr),
              let month = monthNames[monthStr],
              let day = Int(dayStr) else { return nil }

        // Part 1: HHMMSS (e.g., "172146")
        let timeStr = String(parts[1])
        guard timeStr.count == 6,
              let hour = Int(timeStr.prefix(2)),
              let minute = Int(timeStr.dropFirst(2).prefix(2)),
              let second = Int(timeStr.dropFirst(4)) else { return nil }

        // Part 2: ModeNN (e.g., "Rec00", "Wip02")
        let modePart = String(parts[2])
        let modeStr = String(modePart.prefix(3))
        let mode: RecordingMode
        switch modeStr {
        case "Rec": mode = .standard
        case "Pho": mode = .phone
        case "Mee": mode = .meeting
        case "Wip": mode = .wip
        default: mode = .unknown
        }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        let comps = DateComponents(year: year, month: month, day: day,
                                   hour: hour, minute: minute, second: second)
        let date = cal.date(from: comps)

        return ParsedFilename(mode: mode, date: date, originalFilename: filename)
    }

    // MARK: - Legacy format: REC_YYYYMMDD_HHMMSS.hda

    private static func parseLegacyFormat(_ filename: String) -> ParsedFilename {
        let name = (filename as NSString).deletingPathExtension
        let parts = name.split(separator: "_", maxSplits: 2)
        guard parts.count >= 3 else {
            return ParsedFilename(mode: .unknown, date: nil, originalFilename: filename)
        }

        let modeStr = String(parts[0])
        let dateStr = String(parts[1])
        let timeStr = String(parts[2])

        let mode: RecordingMode
        switch modeStr.uppercased() {
        case "REC": mode = .standard
        case "PHONE": mode = .phone
        case "MEET": mode = .meeting
        default: mode = .unknown
        }

        guard dateStr.count == 8, timeStr.count == 6 else {
            return ParsedFilename(mode: mode, date: nil, originalFilename: filename)
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        formatter.timeZone = TimeZone.current
        let date = formatter.date(from: "\(dateStr)_\(timeStr)")

        return ParsedFilename(mode: mode, date: date, originalFilename: filename)
    }
}
