// © 2026 High Gain Design. All rights reserved.

import AVFoundation
import Foundation
import XCTest
@testable import HiDockKit

final class MP3ConcatenatorTests: XCTestCase {
    func testReplacesSourceDurationHeadersWithoutChangingAudioFrames() throws {
        let first = frame(fill: 0x11)
        let second = frame(bitrate: 11, fill: 0x22)
        var merge = MP3Concatenator()
        try merge.append(frame(tag: "Info") + first)
        try merge.append(frame(tag: "Xing") + second)
        let output = try merge.output()
        XCTAssertEqual(String(decoding: output[21..<25], as: UTF8.self), "Xing")
        XCTAssertEqual(readUInt32(output, at: 29), 2)
        XCTAssertEqual(readUInt32(output, at: 33), UInt32(output.count))
        XCTAssertEqual(output.suffix(first.count + second.count), first + second)
    }

    func testSkipsID3TagsAndTheirEmbeddedFrameSyncs() throws {
        let audio = frame(fill: 0x33)
        let tagBody = frame(fill: 0x44)
        let size = tagBody.count
        var id3 = Data([0x49, 0x44, 0x33, 4, 0, 0])
        id3.append(contentsOf: [21, 14, 7, 0].map { UInt8((size >> $0) & 0x7F) })
        id3.append(tagBody)
        var trailer = Data("TAG".utf8)
        trailer.append(Data(repeating: 0, count: 125))
        var merge = MP3Concatenator()
        try merge.append(id3 + frame(tag: "Info") + audio + trailer)
        let output = try merge.output()
        XCTAssertEqual(readUInt32(output, at: 29), 1)
        XCTAssertEqual(output.suffix(audio.count), audio)
    }

    func testTruncatedInputDoesNotPoisonLaterAppend() throws {
        let audio = frame(fill: 0x55)
        var merge = MP3Concatenator()
        XCTAssertThrowsError(try merge.append(Data(audio.prefix(50))))
        try merge.append(audio)
        XCTAssertEqual(readUInt32(try merge.output(), at: 29), 1)
    }

    func testCRCProtectedMetadataIsRemoved() throws {
        let audio = frame(fill: 0x66)
        var merge = MP3Concatenator()
        try merge.append(frame(tag: "Info", crc: true) + audio)
        XCTAssertEqual(readUInt32(try merge.output(), at: 29), 1)
    }

    func testAppleAudioReaderCanReadBothTaggedSourceFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecordingStore(baseDirectory: directory)
        try await store.setup()
        try copyFixtures(to: directory)
        let result = try await store.mergeRecordings(
            filenames: ["REC_20240201_100000.mp3", "REC_20240202_100000.mp3"], as: "Merged")
        let file = try AVAudioFile(forReading: directory.appendingPathComponent(result.filename))
        let duration = Double(file.length) / file.processingFormat.sampleRate
        XCTAssertGreaterThan(duration, 3.8, "A stale source duration header truncates the merge to two seconds")
        XCTAssertLessThan(duration, 4.3)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        XCTAssertGreaterThan(Double(buffer.frameLength) / buffer.format.sampleRate, 3.8)
        let samples = try XCTUnwrap(buffer.floatChannelData)[0]
        let start = Int(buffer.format.sampleRate * 2.5)
        let end = min(Int(buffer.frameLength), Int(buffer.format.sampleRate * 3))
        guard end > start else {
            return XCTFail("The decoded recording must extend into the second source")
        }
        let energy = (start..<end).reduce(Float(0)) { $0 + abs(samples[$1]) }
        XCTAssertGreaterThan(energy, 1, "The second source must contain decoded audio")
    }

    func testMergePreservesOriginalsAndEarliestDateAfterRescan() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecordingStore(baseDirectory: directory)
        try await store.setup()
        try copyFixtures(to: directory)
        let result = try await store.mergeRecordings(
            filenames: ["REC_20240202_100000.mp3", "REC_20240201_100000.mp3"], as: "Merged")
        let expected = FilenameParsing.parse("REC_20240201_100000.mp3").date
        XCTAssertEqual(result.recordedAt, expected)
        let reloaded = RecordingStore(baseDirectory: directory)
        try await reloaded.setup()
        let recordings = await reloaded.allRecordings()
        XCTAssertEqual(recordings.count, 3)
        XCTAssertEqual(recordings.first { $0.filename == "Merged.mp3" }?.recordedAt, expected)
    }

    func testMergeCannotOverwriteAnOriginal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecordingStore(baseDirectory: directory)
        try await store.setup()
        try copyFixtures(to: directory)
        let original = try Data(contentsOf: directory.appendingPathComponent("REC_20240201_100000.mp3"))
        do {
            _ = try await store.mergeRecordings(
                filenames: ["REC_20240201_100000.mp3", "REC_20240202_100000.mp3"],
                as: "REC_20240201_100000")
            XCTFail("Merge must refuse an existing output name")
        } catch HiDockError.invalidFilename(_) { }
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("REC_20240201_100000.mp3")), original)
        let recordings = await store.allRecordings()
        XCTAssertEqual(recordings.count, 2)
    }

    private func copyFixtures(to directory: URL) throws {
        for (fixture, filename) in [("first", "REC_20240201_100000.mp3"), ("second", "REC_20240202_100000.mp3")] {
            let source = try XCTUnwrap(Bundle.module.url(forResource: fixture, withExtension: "mp3", subdirectory: "Fixtures"))
            try FileManager.default.copyItem(at: source, to: directory.appendingPathComponent(filename))
        }
    }

    private func frame(bitrate: Int = 9, tag: String? = nil, crc: Bool = false, fill: UInt8 = 0) -> Data {
        let rate = bitrate == 11 ? 192 : 128
        var data = Data(repeating: fill, count: 144 * rate * 1000 / 44_100)
        data.replaceSubrange(0..<4, with: [0xFF, crc ? 0xFA : 0xFB, UInt8(bitrate << 4), 0xC0])
        if let tag {
            let offset = crc ? 23 : 21
            data.replaceSubrange(offset..<(offset + 4), with: tag.utf8)
        }
        return data
    }

    private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | UInt32($1) }
    }
    func testMergeRejectsOrphanSummaryBeforeWritingAudio() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecordingStore(baseDirectory: directory)
        try await store.setup()
        let marker = Data("keep this summary".utf8)
        try marker.write(to: directory.appendingPathComponent("merged.summary.json"))
        do {
            _ = try await store.mergeRecordings(filenames: ["first.mp3", "second.mp3"], as: "merged")
            XCTFail("Merge should reject an existing sidecar before touching sources")
        } catch HiDockError.invalidFilename { }
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("merged.summary.json")), marker)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("merged.mp3").path))
    }

}
