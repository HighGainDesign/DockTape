// © 2026 High Gain Design. All rights reserved.

import Foundation

/// Exercises the app's real AVPlayer state; the SPM suite covers HiDockKit only.
@main
struct DockTapePlaybackTests {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    @MainActor
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DockTapePlaybackTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioURL = directory.appendingPathComponent("silence.wav")
        try silentWAV().write(to: audioURL)

        let playback = PlaybackState()
        defer { playback.stop() }
        playback.play(file: "first.mp3", url: audioURL)
        playback.setSegmentTimestamps([(0, 5), (5, 10)], for: "first.mp3")
        try expect(playback.activeSegmentIndex == 0, "Playing transcript should highlight its first segment")

        // A newly selected recording must not replace the playing file's timeline.
        playback.setSegmentTimestamps([(0, 2), (2, 4), (4, 10)], for: "selected.mp3")
        try expect(playback.segmentTimestamps.count == 2, "Selection must not replace playback timestamps")
        playback.togglePlayPause()
        playback.setSegmentTimestamps([], for: "selected.mp3")
        try expect(playback.segmentTimestamps.count == 2, "Selection must not clear paused playback timestamps")

        playback.play(file: "second.mp3", url: audioURL)
        try expect(playback.segmentTimestamps.isEmpty, "New playback must clear the previous transcript")
        try expect(playback.activeSegmentIndex == nil, "New playback must not highlight the old transcript")
        playback.setSegmentTimestamps([(0, 5), (5, 10)], for: "first.mp3")
        try expect(playback.segmentTimestamps.isEmpty, "A late transcript response must be ignored")
        playback.setSegmentTimestamps([(0, 10)], for: "second.mp3")
        try expect(playback.segmentTimestamps.count == 1, "The playing file's transcript must be accepted")
        playback.setSegmentTimestamps([], for: "second.mp3")
        try expect(playback.activeSegmentIndex == nil, "A recording without a transcript must have no highlight")

        playback.stop()
        playback.setSegmentTimestamps([(0, 10)], for: "second.mp3")
        try expect(playback.playingFile == nil && playback.segmentTimestamps.isEmpty,
                   "Stopping must clear the timeline and ignore pending transcript loads")
        print("Playback regression checks passed (9 assertions).")
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(description: message) }
    }

    private static func silentWAV() -> Data {
        let sampleRate: UInt32 = 16_000
        let byteCount = sampleRate * 2 * 10
        var result = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { result.append(contentsOf: $0) }
        }
        result.append(Data("RIFF".utf8))
        append(byteCount + 36)
        result.append(Data("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(sampleRate)
        append(sampleRate * 2)
        append(UInt16(2))
        append(UInt16(16))
        result.append(Data("data".utf8))
        append(byteCount)
        result.append(Data(repeating: 0, count: Int(byteCount)))
        return result
    }
}
