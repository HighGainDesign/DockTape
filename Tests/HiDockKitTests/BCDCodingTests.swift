import XCTest
@testable import HiDockKit

final class BCDCodingTests: XCTestCase {

    func testEncodeByte() {
        XCTAssertEqual(BCDCoding.encodeByte(0), 0x00)
        XCTAssertEqual(BCDCoding.encodeByte(9), 0x09)
        XCTAssertEqual(BCDCoding.encodeByte(10), 0x10)
        XCTAssertEqual(BCDCoding.encodeByte(15), 0x15)
        XCTAssertEqual(BCDCoding.encodeByte(20), 0x20)
        XCTAssertEqual(BCDCoding.encodeByte(24), 0x24)
        XCTAssertEqual(BCDCoding.encodeByte(59), 0x59)
        XCTAssertEqual(BCDCoding.encodeByte(99), 0x99)
    }

    func testDecodeByte() {
        XCTAssertEqual(BCDCoding.decodeByte(0x00), 0)
        XCTAssertEqual(BCDCoding.decodeByte(0x09), 9)
        XCTAssertEqual(BCDCoding.decodeByte(0x10), 10)
        XCTAssertEqual(BCDCoding.decodeByte(0x24), 24)
        XCTAssertEqual(BCDCoding.decodeByte(0x59), 59)
        XCTAssertEqual(BCDCoding.decodeByte(0x99), 99)
    }

    func testRoundTripByte() {
        for value in 0...99 {
            let encoded = BCDCoding.encodeByte(value)
            let decoded = BCDCoding.decodeByte(encoded)
            XCTAssertEqual(decoded, value, "Round-trip failed for \(value)")
        }
    }

    func testEncodeDateKnownValue() {
        // 2024-03-15 14:30:00
        var comps = DateComponents()
        comps.year = 2024; comps.month = 3; comps.day = 15
        comps.hour = 14; comps.minute = 30; comps.second = 0
        comps.timeZone = TimeZone.current
        let date = Calendar(identifier: .gregorian).date(from: comps)!

        let encoded = BCDCoding.encodeDate(date)
        XCTAssertEqual(encoded.count, 7)
        XCTAssertEqual(encoded[0], 0x20) // year hi
        XCTAssertEqual(encoded[1], 0x24) // year lo
        XCTAssertEqual(encoded[2], 0x03) // month
        XCTAssertEqual(encoded[3], 0x15) // day
        XCTAssertEqual(encoded[4], 0x14) // hour
        XCTAssertEqual(encoded[5], 0x30) // minute
        XCTAssertEqual(encoded[6], 0x00) // second
    }

    func testDecodeDateKnownValue() {
        let data = Data([0x20, 0x24, 0x03, 0x15, 0x14, 0x30, 0x00])
        let date = BCDCoding.decodeDate(from: data)
        XCTAssertNotNil(date)

        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents(in: TimeZone.current, from: date!)
        XCTAssertEqual(comps.year, 2024)
        XCTAssertEqual(comps.month, 3)
        XCTAssertEqual(comps.day, 15)
        XCTAssertEqual(comps.hour, 14)
        XCTAssertEqual(comps.minute, 30)
        XCTAssertEqual(comps.second, 0)
    }

    func testDecodeDateRoundTrip() {
        let now = Date()
        let encoded = BCDCoding.encodeDate(now)
        let decoded = BCDCoding.decodeDate(from: encoded)
        XCTAssertNotNil(decoded)

        // Should match to the second
        let cal = Calendar(identifier: .gregorian)
        let origComps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
        let decodedComps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: decoded!)
        XCTAssertEqual(origComps.year, decodedComps.year)
        XCTAssertEqual(origComps.month, decodedComps.month)
        XCTAssertEqual(origComps.day, decodedComps.day)
        XCTAssertEqual(origComps.hour, decodedComps.hour)
        XCTAssertEqual(origComps.minute, decodedComps.minute)
        XCTAssertEqual(origComps.second, decodedComps.second)
    }

    func testDecodeTooShort() {
        let data = Data([0x20, 0x24, 0x03])
        XCTAssertNil(BCDCoding.decodeDate(from: data))
    }

    func testDecodeWithOffset() {
        var data = Data([0x00, 0x00]) // 2 bytes prefix
        data.append(contentsOf: [0x20, 0x24, 0x03, 0x15, 0x14, 0x30, 0x00] as [UInt8])
        let date = BCDCoding.decodeDate(from: data, at: 2)
        XCTAssertNotNil(date)
    }

    func testEncodeByteClamps() {
        // Negative → 0
        XCTAssertEqual(BCDCoding.encodeByte(-5), 0x00)
        // >99 → 99
        XCTAssertEqual(BCDCoding.encodeByte(150), 0x99)
    }
}
