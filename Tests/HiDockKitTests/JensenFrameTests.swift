import XCTest
@testable import HiDockKit

final class JensenFrameTests: XCTestCase {

    func testEncodeMinimalFrame() {
        let frame = JensenFrame(command: .deviceInfo, sequence: 1, body: Data())
        let encoded = frame.encode()

        // No padding for host-sent frames — just header (12 bytes)
        XCTAssertEqual(encoded.count, 12)
        // Magic
        XCTAssertEqual(encoded.readUInt16BE(at: 0), 0x1234)
        // Command
        XCTAssertEqual(encoded.readUInt16BE(at: 2), 0x0001)
        // Sequence
        XCTAssertEqual(encoded.readUInt32BE(at: 4), 1)
        // Length field: padding=0, bodyLen=0
        XCTAssertEqual(encoded.readUInt32BE(at: 8), 0)
    }

    func testEncodeWithBody() {
        let body = Data([0xAA, 0xBB, 0xCC])
        let frame = JensenFrame(command: .fileList, sequence: 42, body: body)
        let encoded = frame.encode()

        // header(12) + body(3) = 15, no padding
        XCTAssertEqual(encoded.count, 15)
        XCTAssertEqual(encoded.readUInt16BE(at: 2), JensenCommand.fileList.rawValue)
        XCTAssertEqual(encoded.readUInt32BE(at: 4), 42)
        // Length field: padding=0 in upper byte, bodyLen=3 in lower 24 bits
        XCTAssertEqual(encoded.readUInt32BE(at: 8), 3)
        XCTAssertEqual(encoded[12], 0xAA)
        XCTAssertEqual(encoded[13], 0xBB)
        XCTAssertEqual(encoded[14], 0xCC)
    }

    func testEncodeLargeBody() {
        let body = Data(repeating: 0xFF, count: 505)
        let frame = JensenFrame(command: .deviceInfo, sequence: 0, body: body)
        let encoded = frame.encode()

        // header(12) + body(505) = 517, no padding for host
        XCTAssertEqual(encoded.count, 517)
    }

    func testDecodeRoundTrip() {
        let body = Data([0x01, 0x02, 0x03, 0x04])
        let original = JensenFrame(command: .battery, sequence: 100, body: body)
        let encoded = original.encode()

        let decoded = JensenFrame.decode(from: encoded)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded!.command, .battery)
        XCTAssertEqual(decoded!.sequence, 100)
        XCTAssertEqual(decoded!.body, body)
    }

    func testDecodeWithPadding() {
        // Simulate a device response with padding in the length field
        var data = Data()
        data.appendUInt16BE(0x1234)           // magic
        data.appendUInt16BE(0x0001)           // deviceInfo
        data.appendUInt32BE(1)                // sequence
        // Length field: padding=5 in upper byte, bodyLen=3 in lower 24 bits
        data.appendUInt32BE((5 << 24) | 3)
        data.append(Data([0xAA, 0xBB, 0xCC]))  // 3 bytes body
        data.append(Data(repeating: 0, count: 5))  // 5 bytes padding

        let decoded = JensenFrame.decode(from: data)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded!.command, .deviceInfo)
        XCTAssertEqual(decoded!.body, Data([0xAA, 0xBB, 0xCC]))
    }

    func testDecodeWithPaddingTooShort() {
        // Data that claims 5 bytes padding but doesn't have enough
        var data = Data()
        data.appendUInt16BE(0x1234)
        data.appendUInt16BE(0x0001)
        data.appendUInt32BE(1)
        data.appendUInt32BE((5 << 24) | 3)  // needs 12 + 3 + 5 = 20 bytes
        data.append(Data([0xAA, 0xBB, 0xCC]))  // body only, no padding
        // Total = 15, need 20
        XCTAssertNil(JensenFrame.decode(from: data))
    }

    func testDecodeInvalidMagic() {
        var data = Data(repeating: 0, count: 12)
        data[0] = 0xFF
        data[1] = 0xFF
        XCTAssertNil(JensenFrame.decode(from: data))
    }

    func testDecodeTooShort() {
        let data = Data([0x12, 0x34, 0x00])
        XCTAssertNil(JensenFrame.decode(from: data))
    }

    func testDecodeUnknownCommand() {
        var data = Data(repeating: 0, count: 12)
        data[0] = 0x12; data[1] = 0x34
        data[2] = 0xFF; data[3] = 0xFE  // Unknown command 0xFFFE
        XCTAssertNil(JensenFrame.decode(from: data))
    }

    func testFrameSizeFromHeader() {
        var data = Data()
        data.appendUInt16BE(0x1234)
        data.appendUInt16BE(0x0001)
        data.appendUInt32BE(1)
        // padding=10, bodyLen=100
        data.appendUInt32BE((10 << 24) | 100)

        let size = JensenFrame.frameSizeFromHeader(data)
        XCTAssertEqual(size, 12 + 100 + 10)  // 122
    }

    func testFrameSizeFromHeaderTooShort() {
        let data = Data([0x12, 0x34])
        XCTAssertNil(JensenFrame.frameSizeFromHeader(data))
    }
}
