// © 2026 High Gain Design. All rights reserved.

import XCTest
@testable import HiDockKit

final class JensenParsersTests: XCTestCase {

    // MARK: - DeviceInfo

    func testParseDeviceInfo() throws {
        // 4 version bytes + variable-length serial
        var body = Data()
        body.append(contentsOf: [1, 2, 3, 4])  // version 1.2.3.4
        body.append(contentsOf: "SN12345678".utf8)

        let info = try JensenParsers.parseDeviceInfo(body)
        XCTAssertEqual(info.firmwareVersion, "1.2.3.4")
        XCTAssertEqual(info.serialNumber, "SN12345678")
    }

    func testParseDeviceInfoRealDevice() throws {
        // Actual response from HiDock P1: 17 bytes
        let body = Data([0x00, 0x01, 0x02, 0x19,
            0x48, 0x44, 0x50, 0x31, 0x32, 0x35, 0x34, 0x35, 0x30, 0x36, 0x39, 0x32, 0x33])
        let info = try JensenParsers.parseDeviceInfo(body)
        XCTAssertEqual(info.firmwareVersion, "0.1.2.25")
        XCTAssertEqual(info.serialNumber, "HDP1254506923")
    }

    func testParseDeviceInfoTooShort() {
        let body = Data(repeating: 0, count: 4)  // need at least 5
        XCTAssertThrowsError(try JensenParsers.parseDeviceInfo(body))
    }

    // MARK: - Battery

    func testParseBattery() throws {
        let body = Data([1, 75])  // status=charging, 75%
        let battery = try JensenParsers.parseBattery(body)
        XCTAssertEqual(battery.level, 75)
        XCTAssertEqual(battery.status, .charging)
        XCTAssertTrue(battery.isCharging)
    }

    func testParseBatteryWithVoltage() throws {
        var body = Data([0, 100])  // status=idle, 100%
        body.appendUInt32BE(4200)  // 4200 mV
        let battery = try JensenParsers.parseBattery(body)
        XCTAssertEqual(battery.level, 100)
        XCTAssertEqual(battery.status, .idle)
        XCTAssertFalse(battery.isCharging)
        XCTAssertEqual(battery.voltageMV, 4200)
    }

    func testParseP1BatteryVoltageInMicrovolts() throws {
        var body = Data([2, 100])
        body.appendUInt32BE(4_198_000)
        let battery = try JensenParsers.parseBattery(body)
        XCTAssertEqual(battery.voltageMV, 4198)
        XCTAssertEqual(battery.status, .full)
    }

    func testParseBatteryTooShort() {
        let body = Data([50])
        XCTAssertThrowsError(try JensenParsers.parseBattery(body))
    }

    // MARK: - CardInfo

    func testParseCardInfo() throws {
        var body = Data()
        body.appendUInt32BE(8192)   // used MB
        body.appendUInt32BE(16384)  // capacity MB
        body.appendUInt32BE(0)      // status

        let card = try JensenParsers.parseCardInfo(body)
        XCTAssertEqual(card.freeMB, 8192)
        XCTAssertEqual(card.capacityMB, 16384)
        XCTAssertEqual(card.totalBytes, 16384 * 1024 * 1024)
        XCTAssertEqual(card.usedBytes, 8192 * 1024 * 1024)
        XCTAssertTrue(card.isInserted)
        XCTAssertEqual(card.usagePercent, 50.0, accuracy: 0.01)
    }

    func testParseCardInfoTooShort() {
        let body = Data(repeating: 0, count: 8)
        XCTAssertThrowsError(try JensenParsers.parseCardInfo(body))
    }

    // MARK: - FileCount

    func testParseFileCount() throws {
        var body = Data()
        body.appendUInt32BE(42)
        let count = try JensenParsers.parseFileCount(body)
        XCTAssertEqual(count, 42)
    }

    // MARK: - FileList

    func testParseFileList() throws {
        var body = Data()
        // Entry 1: version=0, nameLen=23 (3 bytes BE), name, size=1024, timestamp(6), md5(16)
        let name1 = "REC_20240315_143000.hda"
        body.append(0)  // version
        body.append(0); body.append(0); body.append(UInt8(name1.count))  // nameLen (24-bit BE)
        body.append(contentsOf: name1.utf8)
        body.appendUInt32BE(1024)  // size
        body.append(Data(repeating: 0, count: 6))  // timestamp
        body.append(Data(repeating: 0xAB, count: 16))  // md5

        // Entry 2
        let name2 = "PHONE_20240316_090000.hda"
        body.append(1)  // version
        body.append(0); body.append(0); body.append(UInt8(name2.count))
        body.append(contentsOf: name2.utf8)
        body.appendUInt32BE(2048)
        body.append(Data(repeating: 0, count: 6))
        body.append(Data(repeating: 0xCD, count: 16))

        let entries = try JensenParsers.parseFileList(body)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].filename, name1)
        XCTAssertEqual(entries[0].size, 1024)
        XCTAssertEqual(entries[0].version, 0)
        XCTAssertEqual(entries[1].filename, name2)
        XCTAssertEqual(entries[1].size, 2048)
        XCTAssertEqual(entries[1].version, 1)
    }

    func testParseFileListWithHeader() throws {
        var body = Data()
        // Optional 0xFF 0xFF header + 4-byte count
        body.append(contentsOf: [0xFF, 0xFF])
        body.appendUInt32BE(1)  // file count

        // One entry
        let name = "test.hda"
        body.append(0)
        body.append(0); body.append(0); body.append(UInt8(name.count))
        body.append(contentsOf: name.utf8)
        body.appendUInt32BE(512)
        body.append(Data(repeating: 0, count: 6))
        body.append(Data(repeating: 0xFF, count: 16))

        let entries = try JensenParsers.parseFileList(body)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].filename, "test.hda")
        XCTAssertEqual(entries[0].size, 512)
    }

    func testParseFileListEmpty() throws {
        let entries = try JensenParsers.parseFileList(Data())
        XCTAssertEqual(entries.count, 0)
    }

    // MARK: - Settings

    func testParseSettings() throws {
        // 12 bytes: autoRecord at [3], autoPlay at [7], notification at [11]
        var body = Data(repeating: 0, count: 12)
        body[3] = 1   // autoRecord enabled
        body[7] = 2   // autoPlay disabled
        body[11] = 1  // notification enabled

        let settings = try JensenParsers.parseSettings(body)
        XCTAssertTrue(settings.autoRecord)
        XCTAssertFalse(settings.autoPlay)
        XCTAssertTrue(settings.notification)
    }

    func testParseSettingsTooShort() {
        let body = Data(repeating: 0, count: 4)
        XCTAssertThrowsError(try JensenParsers.parseSettings(body))
    }

    func testSettingsEncode() {
        let settings = DeviceSettings(autoRecord: true, autoPlay: false, notification: true)
        let encoded = settings.encode()
        XCTAssertEqual(encoded.count, 12)
        XCTAssertEqual(encoded[3], 1)   // autoRecord enabled
        XCTAssertEqual(encoded[7], 2)   // autoPlay disabled
        XCTAssertEqual(encoded[11], 1)  // notification enabled
    }

    // MARK: - Time

    func testParseTime() throws {
        let body = Data([0x20, 0x24, 0x06, 0x01, 0x12, 0x00, 0x00])
        let date = try JensenParsers.parseTime(body)
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents(in: TimeZone.current, from: date)
        XCTAssertEqual(comps.year, 2024)
        XCTAssertEqual(comps.month, 6)
        XCTAssertEqual(comps.day, 1)
        XCTAssertEqual(comps.hour, 12)
    }

    // MARK: - Command Result

    func testParseCommandResultSuccess() throws {
        XCTAssertNoThrow(try JensenParsers.parseCommandResult(Data([0x00])))
    }

    func testParseCommandResultFailure() throws {
        XCTAssertThrowsError(try JensenParsers.parseCommandResult(Data([0x01])))
    }
}
