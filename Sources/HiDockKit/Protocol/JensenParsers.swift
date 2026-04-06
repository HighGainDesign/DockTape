import Foundation

/// Parsed device info from a DeviceInfo response.
/// Body layout: 4 version bytes + 16-byte serial number.
public struct DeviceInfo: Sendable {
    public let firmwareVersion: String
    public let serialNumber: String

    public init(firmwareVersion: String, serialNumber: String) {
        self.firmwareVersion = firmwareVersion
        self.serialNumber = serialNumber
    }
}

/// Parsed battery info.
/// Body layout: status(1) + percentage(1) + voltage(4 optional).
public struct BatteryInfo: Sendable {
    public let status: BatteryStatus
    public let level: Int       // 0–100 percentage
    public let voltageMV: UInt32?  // millivolts, if available

    public enum BatteryStatus: UInt8, Sendable {
        case idle = 0
        case charging = 1
        case full = 2
    }

    public var isCharging: Bool { status == .charging }

    public init(status: BatteryStatus, level: Int, voltageMV: UInt32? = nil) {
        self.status = status
        self.level = level
        self.voltageMV = voltageMV
    }
}

/// Parsed SD card / built-in storage info.
/// Body layout: freeMB(4) + capacityMB(4) + status(4).
public struct CardInfo: Sendable {
    public let freeMB: UInt32
    public let capacityMB: UInt32
    public let statusCode: UInt32

    public init(freeMB: UInt32, capacityMB: UInt32, statusCode: UInt32) {
        self.freeMB = freeMB
        self.capacityMB = capacityMB
        self.statusCode = statusCode
    }

    public var totalBytes: UInt64 { UInt64(capacityMB) * 1024 * 1024 }
    public var freeBytes: UInt64 { UInt64(freeMB) * 1024 * 1024 }
    public var usedBytes: UInt64 {
        let total = UInt64(capacityMB)
        let free = UInt64(freeMB)
        return total > free ? (total - free) * 1024 * 1024 : 0
    }
    public var isInserted: Bool { capacityMB > 0 }
    public var usagePercent: Double {
        guard capacityMB > 0 else { return 0 }
        return Double(capacityMB - freeMB) / Double(capacityMB) * 100
    }
}

/// A file entry from the device's file list.
public struct FileEntry: Sendable, Identifiable {
    public let id: String   // filename
    public let filename: String
    public let size: UInt32
    public let version: UInt8
    public let md5: String

    public init(filename: String, size: UInt32, version: UInt8 = 0, md5: String = "") {
        self.id = filename
        self.filename = filename
        self.size = size
        self.version = version
        self.md5 = md5
    }
}

/// Device settings.
/// Body layout: 12 bytes. autoRecord at [3], autoPlay at [7], notification at [11].
/// Values: 1=enabled, 2=disabled, 0=unchanged (for writes).
public struct DeviceSettings: Sendable {
    public var autoRecord: Bool
    public var autoPlay: Bool
    public var notification: Bool

    public init(autoRecord: Bool = false, autoPlay: Bool = false, notification: Bool = true) {
        self.autoRecord = autoRecord
        self.autoPlay = autoPlay
        self.notification = notification
    }

    /// Encode settings to 12-byte body for SetSettings command.
    /// Uses 1=enable, 2=disable for each setting, 0=unchanged for others.
    public func encode() -> Data {
        var data = Data(repeating: 0, count: 12)
        data[3] = autoRecord ? 1 : 2
        data[7] = autoPlay ? 1 : 2
        data[11] = notification ? 1 : 2
        return data
    }
}

/// Parsers for Jensen protocol response bodies.
public enum JensenParsers {

    /// Parse DeviceInfo response.
    /// Body: 4 version bytes + remaining bytes are serial number (ASCII, variable length).
    /// Real device returns 17 bytes (4 version + 13 serial), not necessarily padded to 16.
    public static func parseDeviceInfo(_ body: Data) throws -> DeviceInfo {
        guard body.count >= 5 else {
            throw ProtocolError.responseTooShort(expected: 5, got: body.count)
        }
        let v0 = body[body.startIndex]
        let v1 = body[body.startIndex + 1]
        let v2 = body[body.startIndex + 2]
        let v3 = body[body.startIndex + 3]
        let version = "\(v0).\(v1).\(v2).\(v3)"

        let serialData = body.subdata(in: (body.startIndex + 4) ..< body.endIndex)
        let serial = extractNullTerminatedString(from: serialData)

        return DeviceInfo(firmwareVersion: version, serialNumber: serial)
    }

    /// Parse Battery response.
    /// Body: status(1) + percentage(1) + optional voltage(4 BE).
    public static func parseBattery(_ body: Data) throws -> BatteryInfo {
        guard body.count >= 2 else {
            throw ProtocolError.responseTooShort(expected: 2, got: body.count)
        }
        let statusByte = body[body.startIndex]
        let status = BatteryInfo.BatteryStatus(rawValue: statusByte) ?? .idle
        let level = Int(body[body.startIndex + 1])
        let voltage: UInt32? = body.count >= 6 ? body.readUInt32BE(at: 2) : nil
        return BatteryInfo(status: status, level: level, voltageMV: voltage)
    }

    /// Parse CardInfo response.
    /// Body: freeMB(4 BE) + capacityMB(4 BE) + status(4 BE).
    public static func parseCardInfo(_ body: Data) throws -> CardInfo {
        guard body.count >= 12 else {
            throw ProtocolError.responseTooShort(expected: 12, got: body.count)
        }
        let freeMB = body.readUInt32BE(at: 0)
        let capacityMB = body.readUInt32BE(at: 4)
        let statusCode = body.readUInt32BE(at: 8)
        return CardInfo(freeMB: freeMB, capacityMB: capacityMB, statusCode: statusCode)
    }

    /// Parse FileCount response.
    /// Body: 4 bytes count (BE).
    public static func parseFileCount(_ body: Data) throws -> Int {
        guard body.count >= 4 else {
            throw ProtocolError.responseTooShort(expected: 4, got: body.count)
        }
        return Int(body.readUInt32BE(at: 0))
    }

    /// Parse FileList response body into file entries.
    /// Format: optional 0xFF 0xFF header, then per-entry:
    ///   version(1) + nameLen(3 BE) + name(N) + size(4 BE) + timestamp(6) + md5(16)
    public static func parseFileList(_ body: Data) throws -> [FileEntry] {
        var entries: [FileEntry] = []
        var offset = 0
        let count = body.count

        // Skip optional 0xFF 0xFF header + 4-byte file count
        if count >= 6 && body[body.startIndex] == 0xFF && body[body.startIndex + 1] == 0xFF {
            offset = 6
        }

        while offset < count {
            // Need at least: version(1) + nameLen(3) = 4 bytes
            guard offset + 4 <= count else { break }

            let version = body[body.startIndex + offset]
            let nameLen = (Int(body[body.startIndex + offset + 1]) << 16)
                        | (Int(body[body.startIndex + offset + 2]) << 8)
                        | Int(body[body.startIndex + offset + 3])
            offset += 4

            // Need: name(nameLen) + size(4) + timestamp(6) + md5(16) = nameLen + 26
            guard offset + nameLen + 26 <= count else { break }

            let nameData = body.subdata(in: (body.startIndex + offset) ..< (body.startIndex + offset + nameLen))
            // Strip null bytes from filename
            let filename = String(data: nameData.filter { $0 != 0 }, encoding: .utf8) ?? "unknown"
            offset += nameLen

            let fileSize = body.readUInt32BE(at: offset)
            offset += 4

            // Skip 6-byte timestamp
            offset += 6

            // Read 16-byte MD5
            let md5Data = body.subdata(in: (body.startIndex + offset) ..< (body.startIndex + offset + 16))
            let md5 = md5Data.map { String(format: "%02x", $0) }.joined()
            offset += 16

            entries.append(FileEntry(filename: filename, size: fileSize, version: version, md5: md5))
        }

        return entries
    }

    /// Parse GetSettings response.
    /// Body: 12 bytes. autoRecord at [3], autoPlay at [7], notification at [11].
    /// Values: 1=enabled, 2=disabled.
    public static func parseSettings(_ body: Data) throws -> DeviceSettings {
        guard body.count >= 12 else {
            throw ProtocolError.responseTooShort(expected: 12, got: body.count)
        }
        return DeviceSettings(
            autoRecord: body[body.startIndex + 3] == 1,
            autoPlay: body[body.startIndex + 7] == 1,
            notification: body[body.startIndex + 11] == 1
        )
    }

    /// Parse GetTime response — 7 BCD bytes.
    public static func parseTime(_ body: Data) throws -> Date {
        guard let date = BCDCoding.decodeDate(from: body) else {
            throw ProtocolError.invalidBody("Cannot decode BCD time from \(body.count) bytes")
        }
        return date
    }

    /// Parse a generic command result (1 byte: 0x00 = success).
    public static func parseCommandResult(_ body: Data) throws {
        guard body.count >= 1 else {
            throw ProtocolError.responseTooShort(expected: 1, got: body.count)
        }
        if body[body.startIndex] != 0x00 {
            throw ProtocolError.commandFailed(body[body.startIndex])
        }
    }

    // MARK: - Helpers

    private static func extractNullTerminatedString(from data: Data) -> String {
        if let nullIndex = data.firstIndex(of: 0) {
            let trimmed = data[data.startIndex ..< nullIndex]
            return String(data: trimmed, encoding: .utf8) ?? ""
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
