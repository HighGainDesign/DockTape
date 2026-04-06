import Foundation

extension Data {
    /// Read a big-endian UInt16 at the given byte offset.
    public func readUInt16BE(at offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        return UInt16(self[startIndex + offset]) << 8
             | UInt16(self[startIndex + offset + 1])
    }

    /// Read a big-endian UInt32 at the given byte offset.
    public func readUInt32BE(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return UInt32(self[startIndex + offset]) << 24
             | UInt32(self[startIndex + offset + 1]) << 16
             | UInt32(self[startIndex + offset + 2]) << 8
             | UInt32(self[startIndex + offset + 3])
    }

    /// Read a single byte at the given offset.
    public func readByte(at offset: Int) -> UInt8 {
        guard offset < count else { return 0 }
        return self[startIndex + offset]
    }

    /// Append a big-endian UInt16.
    public mutating func appendUInt16BE(_ value: UInt16) {
        append(UInt8(value >> 8))
        append(UInt8(value & 0xFF))
    }

    /// Append a big-endian UInt32.
    public mutating func appendUInt32BE(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }
}
