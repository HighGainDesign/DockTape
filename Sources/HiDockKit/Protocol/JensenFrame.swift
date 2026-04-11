// © 2026 High Gain Design. All rights reserved.

import Foundation

/// Jensen wire-protocol frame encoder/decoder.
///
/// Wire format (big-endian):
/// - 2 bytes: magic (0x12 0x34)
/// - 2 bytes: command ID
/// - 4 bytes: sequence number
/// - 4 bytes: length field — upper byte = padding count P, lower 3 bytes = body length N
/// - N bytes: body
/// - P bytes: padding (zeros, device responses only)
///
/// Host-sent frames always use padding = 0 (just header + body, no padding).
public struct JensenFrame: Sendable {
    public static let magic: UInt16 = 0x1234
    public static let headerSize = 12

    public let command: JensenCommand
    public let sequence: UInt32
    public let body: Data

    public init(command: JensenCommand, sequence: UInt32, body: Data = Data()) {
        self.command = command
        self.sequence = sequence
        self.body = body
    }

    /// Encode frame to wire bytes. Host sends no padding — just header + body.
    public func encode() -> Data {
        var data = Data()
        data.reserveCapacity(Self.headerSize + body.count)
        data.appendUInt16BE(Self.magic)
        data.appendUInt16BE(command.rawValue)
        data.appendUInt32BE(sequence)
        // Length field: padding=0 in upper byte, body length in lower 24 bits
        data.appendUInt32BE(UInt32(body.count) & 0x00FFFFFF)
        data.append(body)
        return data
    }

    /// Decode a frame from wire bytes. Returns nil if data is too short or magic doesn't match.
    /// Handles the compound length field: upper byte = padding, lower 3 bytes = body length.
    public static func decode(from data: Data) -> JensenFrame? {
        guard data.count >= headerSize else { return nil }

        let magicValue = data.readUInt16BE(at: 0)
        guard magicValue == magic else { return nil }

        guard let cmd = JensenCommand(rawValue: data.readUInt16BE(at: 2)) else { return nil }
        let seq = data.readUInt32BE(at: 4)
        let lengthField = data.readUInt32BE(at: 8)

        // Decode compound length: upper byte = padding, lower 24 bits = body length
        let padding = Int((lengthField >> 24) & 0xFF)
        let bodyLength = Int(lengthField & 0x00FFFFFF)
        let totalNeeded = headerSize + bodyLength + padding

        guard data.count >= totalNeeded else { return nil }

        let body = data.subdata(in: headerSize ..< headerSize + bodyLength)
        return JensenFrame(command: cmd, sequence: seq, body: body)
    }

    /// Returns the total frame size needed to fully decode this frame from wire data.
    /// Useful for transport layer to know how much data to accumulate.
    public static func frameSizeFromHeader(_ data: Data) -> Int? {
        guard data.count >= headerSize else { return nil }
        let lengthField = data.readUInt32BE(at: 8)
        let padding = Int((lengthField >> 24) & 0xFF)
        let bodyLength = Int(lengthField & 0x00FFFFFF)
        return headerSize + bodyLength + padding
    }
}
