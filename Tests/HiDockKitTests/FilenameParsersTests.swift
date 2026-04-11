// © 2026 High Gain Design. All rights reserved.

import XCTest
@testable import HiDockKit

final class FilenameParsingTests: XCTestCase {

    // MARK: - Real device format

    func testParseRealDeviceRecording() {
        let result = FilenameParsing.parse("2026Mar30-172146-Rec00.hda")
        XCTAssertEqual(result.mode, .standard)
        XCTAssertNotNil(result.date)

        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: result.date!)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 3)
        XCTAssertEqual(comps.day, 30)
        XCTAssertEqual(comps.hour, 17)
        XCTAssertEqual(comps.minute, 21)
        XCTAssertEqual(comps.second, 46)
    }

    func testParseRealDeviceWip() {
        let result = FilenameParsing.parse("2026Apr05-005218-Wip02.hda")
        XCTAssertEqual(result.mode, .wip)
        XCTAssertNotNil(result.date)

        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents([.year, .month, .day], from: result.date!)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 4)
        XCTAssertEqual(comps.day, 5)
    }

    func testParseDevicePhone() {
        let result = FilenameParsing.parse("2024Nov15-091500-Pho00.hda")
        XCTAssertEqual(result.mode, .phone)
        XCTAssertNotNil(result.date)
    }

    func testParseDeviceMeeting() {
        let result = FilenameParsing.parse("2024Dec01-140000-Mee01.hda")
        XCTAssertEqual(result.mode, .meeting)
        XCTAssertNotNil(result.date)
    }

    // MARK: - Legacy format

    func testParseLegacyStandard() {
        let result = FilenameParsing.parse("REC_20240315_143000.hda")
        XCTAssertEqual(result.mode, .standard)
        XCTAssertNotNil(result.date)
    }

    func testParseLegacyPhone() {
        let result = FilenameParsing.parse("PHONE_20240316_090000.hda")
        XCTAssertEqual(result.mode, .phone)
        XCTAssertNotNil(result.date)
    }

    func testParseLegacyCaseInsensitive() {
        let result = FilenameParsing.parse("rec_20240315_143000.hda")
        XCTAssertEqual(result.mode, .standard)
    }

    // MARK: - Edge cases

    func testParseInvalidFilename() {
        let result = FilenameParsing.parse("something.hda")
        XCTAssertEqual(result.mode, .unknown)
        XCTAssertNil(result.date)
    }

    func testParseUnknownDeviceMode() {
        let result = FilenameParsing.parse("2024Nov15-091500-Xyz00.hda")
        XCTAssertEqual(result.mode, .unknown)
        XCTAssertNotNil(result.date)
    }
}
