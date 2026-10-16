// © 2026 High Gain Design. All rights reserved.

import Foundation
import HiDockKit

/// Exercises the app's real AVPlayer state; the SPM suite covers HiDockKit only.
@main
struct DockTapePlaybackTests {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    @MainActor
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DockTapePlaybackTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioURL = directory.appendingPathComponent("silence.wav")
        try silentWAV().write(to: audioURL)

        let playback = PlaybackState()
        defer { playback.stop() }
        playback.play(file: "first.mp3", url: audioURL)
        try await waitUntil { playback.avPlayer != nil || playback.loadError != nil }
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
        try await cloudPlaybackChecks(url: audioURL)
        try await stableReferencePlaybackChecks(url: audioURL)
        try await selectionLoadingChecks()
        print("Playback and selected-content regression checks passed (original9 + cloud/cancellation/selection and shared identity/retry checks).")
    }

    private actor Gate {
        var isWaiting = false
        private var released = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            isWaiting = true
            if released { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func release() { released = true; waiters.forEach { $0.resume() }; waiters.removeAll() }
    }

    @MainActor
    private static func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw Failure(description: "Timed out waiting for regression condition") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor
    private static func cloudPlaybackChecks(url: URL) async throws {
        let gate = Gate()
        let playback = PlaybackState(prepareFile: { _, waiting in
            await waiting(); await gate.wait(); return true
        })
        playback.play(file: "cloud.mp3", url: url)
        try await waitUntil { await gate.isWaiting }
        try expect(playback.isPreparing && !playback.isPlaying, "Pending cloud audio must not be represented as playing")
        try expect(playback.preparationMessage.contains("iCloud Drive"), "Cloud wait needs a visible explanation")
        playback.seek(to: 3)
        playback.stop()
        await gate.release()
        // Cancellation completion must never restart the stopped recording.
        try await Task.sleep(for: .milliseconds(20))
        try expect(playback.playingFile == nil && playback.avPlayer == nil, "Late cloud completion must not restart playback")

        let switchGate = Gate()
        let switching = PlaybackState(prepareFile: { candidate, waiting in
            if candidate.lastPathComponent == "pending.wav" { await waiting(); await switchGate.wait() }
            return true
        })
        switching.play(file: "a.mp3", url: url.deletingLastPathComponent().appendingPathComponent("pending.wav"))
        try await waitUntil { await switchGate.isWaiting }
        switching.play(file: "b.mp3", url: url)
        try await waitUntil { switching.avPlayer != nil || switching.loadError != nil }
        await switchGate.release()
        try await Task.sleep(for: .milliseconds(20))
        try expect(switching.playingFile == "b.mp3" && switching.loadError == nil,
                   "Resident audio must start independently and ignore the cancelled cloud request")
        switching.stop()

        let fixtureURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Tests/HiDockKitTests/Fixtures/first.mp3")
        let mp3 = PlaybackState()
        mp3.play(file: "fixture.mp3", url: fixtureURL)
        try await waitUntil { mp3.avPlayer != nil || mp3.loadError != nil }
        try expect(mp3.loadError == nil && mp3.duration > 1, "Resident MP3 playback must still prepare and measure its duration")
        mp3.stop()

        actor Attempts {
            var count = 0
            func next() -> Int { count += 1; return count }
        }
        let attempts = Attempts()
        let retrying = PlaybackState(prepareFile: { _, _ in
            if await attempts.next() == 1 { throw CocoaError(.fileReadNoPermission) }
            return true
        })
        retrying.play(file: "retry.mp3", url: url)
        try await waitUntil { retrying.loadError != nil }
        retrying.retry()
        try await waitUntil { retrying.avPlayer != nil || retrying.loadError != nil }
        try expect(retrying.avPlayer != nil && retrying.loadError == nil, "Playback Retry must recover without restarting the app")
        retrying.stop()

        let failing = PlaybackState(prepareFile: { _, _ in throw CocoaError(.fileReadNoPermission) })
        failing.play(file: "missing.mp3", url: url)
        try await waitUntil { failing.loadError != nil }
        try expect(!failing.isPlaying && !failing.isPreparing, "Playback errors must exit the waiting state")
        failing.stop()
    }

    @MainActor
    private static func stableReferencePlaybackChecks(url: URL) async throws {
        let parent = url.deletingLastPathComponent().appendingPathComponent("shared-playback")
        let root = parent.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let audio = try Data(contentsOf: url)
        for name in ["Meeting.mp3", "Other.mp3"] { try audio.write(to: root.appendingPathComponent(name)) }
        let coordinator = SharedLibraryCoordinator(root: root, writerID: UUID(), witnessDirectory: parent.appendingPathComponent("local"))
        _ = try await coordinator.enable()
        let selected = try await coordinator.reference(to: "Meeting.mp3")
        let other = try await coordinator.reference(to: "Other.mp3")
        actor Attempts { var count = 0; func next() -> Int { count += 1; return count } }
        let attempts = Attempts()
        let player = PlaybackState(prepareFile: { _, _ in
            if await attempts.next() == 1 { throw CocoaError(.fileReadNoPermission) }
            return true
        })
        player.acquireLease = { filename, _, reference in
            guard let reference else { throw SharedLibraryCoordinatorError.differentBinding }
            let view = try await coordinator.recording(at: filename, reference: reference)
            let token = try await coordinator.pinJob(.init(id: view.state.id, kind: .recording))
            return .init(validate: { try await coordinator.validateJob(token) }, release: { await coordinator.finishJob(token) })
        }
        player.play(file: "Meeting.mp3", url: root.appendingPathComponent("Meeting.mp3"), reference: selected)
        try await waitUntil { player.loadError != nil }
        try expect(player.requestedReference == selected, "A failed preparation retains the selected ID for Retry")
        player.retry()
        try await waitUntil { player.avPlayer != nil || player.loadError != nil }
        try expect(player.avPlayer != nil && player.loadError == nil && player.requestedReference == selected,
            "Retry must reacquire authority for the same selected recording")
        player.play(file: "Meeting.mp3", url: root.appendingPathComponent("Meeting.mp3"), reference: other)
        try await waitUntil { player.loadError != nil }
        try expect(player.avPlayer == nil && player.requestedReference == other,
            "Reusing a filename with another ID must begin a new validated request and reject its path mismatch")
        player.stop()
        try expect(try Data(contentsOf: root.appendingPathComponent("Meeting.mp3")) == audio,
            "Playback and rejected selection preserve original bytes")
    }

    @MainActor
    private static func selectionLoadingChecks() async throws {
        let gate = Gate()
        let state = RecordingContentState<String>()
        let first = Task {
            await state.load(for: "a.mp3") { waiting in
                await waiting(); await gate.wait()
                await waiting() // Deliberately late callback from the previous selection.
                return "A"
            }
        }
        try await waitUntil { await gate.isWaiting }
        try expect(state.isLoading && state.isDownloading, "Pending content should show a download state, not missing content")
        await state.load(for: "b.mp3") { _ in "B" }
        try expect(state.content == "B" && !state.isLoading, "Resident selection must load while A remains pending")
        await gate.release(); await first.value
        try expect(state.filename == "b.mp3" && state.content == "B" && !state.isDownloading,
                   "Late A content and download callbacks must not overwrite B")
        await state.load(for: "bad.mp3") { _ in throw CocoaError(.fileReadNoPermission) }
        try expect(state.errorMessage != nil && !state.isLoading, "Read failures must not masquerade as missing summaries")
        await state.load(for: "bad.mp3") { _ in "Recovered" }
        try expect(state.content == "Recovered" && state.errorMessage == nil, "Retry should recover without restarting the app")
        await state.load(for: "absent.mp3") { _ in nil }
        try expect(state.content == nil && state.errorMessage == nil && !state.isLoading,
                   "Only a completed missing-file lookup should display no content")
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
