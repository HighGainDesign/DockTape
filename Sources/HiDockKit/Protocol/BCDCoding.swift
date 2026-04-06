import Foundation

/// BCD (Binary-Coded Decimal) encoding/decoding for HiDock time fields.
///
/// The device encodes timestamps as BCD bytes: each byte holds two decimal
/// digits (high nibble = tens, low nibble = ones).
/// Format: [year_hi, year_lo, month, day, hour, minute, second]
/// Example: 2024-03-15 14:30:00 → [0x20, 0x24, 0x03, 0x15, 0x14, 0x30, 0x00]
public enum BCDCoding {
    /// Encode a single integer (0–99) as a BCD byte.
    public static func encodeByte(_ value: Int) -> UInt8 {
        let clamped = max(0, min(99, value))
        return UInt8((clamped / 10) << 4 | (clamped % 10))
    }

    /// Decode a BCD byte to an integer.
    public static func decodeByte(_ byte: UInt8) -> Int {
        Int(byte >> 4) * 10 + Int(byte & 0x0F)
    }

    /// Encode a Date to 7 BCD bytes [year_hi, year_lo, month, day, hour, min, sec].
    public static func encodeDate(_ date: Date) -> Data {
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents(in: TimeZone.current, from: date)

        let year = comps.year ?? 2024
        var result = Data(capacity: 7)
        result.append(encodeByte(year / 100))
        result.append(encodeByte(year % 100))
        result.append(encodeByte(comps.month ?? 1))
        result.append(encodeByte(comps.day ?? 1))
        result.append(encodeByte(comps.hour ?? 0))
        result.append(encodeByte(comps.minute ?? 0))
        result.append(encodeByte(comps.second ?? 0))
        return result
    }

    /// Decode 7 BCD bytes to a Date. Returns nil if the bytes don't form a valid date.
    public static func decodeDate(from data: Data, at offset: Int = 0) -> Date? {
        guard data.count >= offset + 7 else { return nil }

        let yearHi = decodeByte(data[data.startIndex + offset])
        let yearLo = decodeByte(data[data.startIndex + offset + 1])
        let month  = decodeByte(data[data.startIndex + offset + 2])
        let day    = decodeByte(data[data.startIndex + offset + 3])
        let hour   = decodeByte(data[data.startIndex + offset + 4])
        let minute = decodeByte(data[data.startIndex + offset + 5])
        let second = decodeByte(data[data.startIndex + offset + 6])

        var comps = DateComponents()
        comps.year = yearHi * 100 + yearLo
        comps.month = month
        comps.day = day
        comps.hour = hour
        comps.minute = minute
        comps.second = second
        comps.timeZone = TimeZone.current

        return Calendar(identifier: .gregorian).date(from: comps)
    }
}
