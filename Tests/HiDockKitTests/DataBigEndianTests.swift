import XCTest
@testable import HiDockKit

final class DataBigEndianTests: XCTestCase {

    func testReadUInt16BE() {
        let data = Data([0x12, 0x34, 0x56, 0x78])
        XCTAssertEqual(data.readUInt16BE(at: 0), 0x1234)
        XCTAssertEqual(data.readUInt16BE(at: 2), 0x5678)
    }

    func testReadUInt32BE() {
        let data = Data([0x12, 0x34, 0x56, 0x78])
        XCTAssertEqual(data.readUInt32BE(at: 0), 0x12345678)
    }

    func testReadByte() {
        let data = Data([0xAB, 0xCD])
        XCTAssertEqual(data.readByte(at: 0), 0xAB)
        XCTAssertEqual(data.readByte(at: 1), 0xCD)
    }

    func testAppendUInt16BE() {
        var data = Data()
        data.appendUInt16BE(0x1234)
        XCTAssertEqual(data, Data([0x12, 0x34]))
    }

    func testAppendUInt32BE() {
        var data = Data()
        data.appendUInt32BE(0xDEADBEEF)
        XCTAssertEqual(data, Data([0xDE, 0xAD, 0xBE, 0xEF]))
    }

    func testOutOfBoundsReturnsZero() {
        let data = Data([0x01])
        XCTAssertEqual(data.readUInt16BE(at: 0), 0)
        XCTAssertEqual(data.readUInt32BE(at: 0), 0)
        XCTAssertEqual(data.readByte(at: 5), 0)
    }
}
