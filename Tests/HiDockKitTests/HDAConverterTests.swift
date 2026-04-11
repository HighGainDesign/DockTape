// © 2026 High Gain Design. All rights reserved.

import XCTest
@testable import HiDockKit

final class HDAConverterTests: XCTestCase {

    func testExtractMP3WithFBSync() {
        // Simulate .hda: some header bytes, then MP3 sync 0xFF 0xFB, then audio
        var hda = Data([0x00, 0x01, 0x02, 0x03, 0x04]) // 5 bytes header junk
        hda.append(contentsOf: [0xFF, 0xFB] as [UInt8])   // MP3 sync word
        hda.append(Data(repeating: 0xAA, count: 100))      // "audio" data

        let mp3 = HDAConverter.extractMP3(from: hda)
        XCTAssertNotNil(mp3)
        XCTAssertEqual(mp3!.count, 102) // sync(2) + audio(100)
        XCTAssertEqual(mp3![0], 0xFF)
        XCTAssertEqual(mp3![1], 0xFB)
    }

    func testExtractMP3WithF3Sync() {
        var hda = Data([0x00, 0x00, 0x00])
        hda.append(contentsOf: [0xFF, 0xF3] as [UInt8])
        hda.append(Data(repeating: 0xBB, count: 50))

        let mp3 = HDAConverter.extractMP3(from: hda)
        XCTAssertNotNil(mp3)
        XCTAssertEqual(mp3!.count, 52)
        XCTAssertEqual(mp3![0], 0xFF)
        XCTAssertEqual(mp3![1], 0xF3)
    }

    func testExtractMP3NoSync() {
        let hda = Data(repeating: 0x42, count: 100)
        XCTAssertNil(HDAConverter.extractMP3(from: hda))
    }

    func testExtractMP3EmptyData() {
        XCTAssertNil(HDAConverter.extractMP3(from: Data()))
        XCTAssertNil(HDAConverter.extractMP3(from: Data([0xFF])))
    }

    func testExtractMP3SyncAtStart() {
        var hda = Data([0xFF, 0xFB])
        hda.append(Data(repeating: 0xCC, count: 200))

        let mp3 = HDAConverter.extractMP3(from: hda)
        XCTAssertNotNil(mp3)
        XCTAssertEqual(mp3!.count, 202)
    }

    func testConvertAndWrite() throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        var hda = Data([0x00, 0x01, 0x02])
        hda.append(contentsOf: [0xFF, 0xFB] as [UInt8])
        hda.append(Data(repeating: 0xDD, count: 50))

        let outputURL = tmpDir.appendingPathComponent("test.mp3")
        try HDAConverter.convertAndWrite(hdaData: hda, to: outputURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        let written = try Data(contentsOf: outputURL)
        XCTAssertEqual(written.count, 52)
        XCTAssertEqual(written[0], 0xFF)
    }

    func testConvertAndWriteNoSync() {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outputURL = tmpDir.appendingPathComponent("test.mp3")
        let hda = Data(repeating: 0x42, count: 100)

        XCTAssertThrowsError(try HDAConverter.convertAndWrite(hdaData: hda, to: outputURL))
    }
}
