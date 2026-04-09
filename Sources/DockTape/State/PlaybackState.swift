import SwiftUI
import AVFoundation

/// Isolated playback state with SwiftUI-driven progress polling.
///
/// Instead of relying on `addPeriodicTimeObserver` (which macOS throttles via App Nap
/// and delivers with unpredictable timing), progress is updated by calling `tick()` from
/// a `TimelineView` in the UI layer. This reads `player.currentTime()` synchronously
/// during the render cycle — no async hops, no GCD scheduling, no ordering issues.
@Observable
@MainActor
final class PlaybackState {
    var playingFile: String?
    var isPlaying: Bool = false
    var progress: Double = 0
    var duration: Double = 0
    var rate: Float = 1.0

    private var avPlayer: AVPlayer?
    private var endOfPlaybackObserver: NSObjectProtocol?

    /// The currently active segment index, derived from progress and segment timestamps.
    var activeSegmentIndex: Int?
    private var segmentTimestamps: [TimeInterval] = []

    static let speeds: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0]

    /// Called by TimelineView on each render tick (~4Hz) to sync progress from the player.
    func tick() {
        guard isPlaying, let player = avPlayer else { return }
        let t = CMTimeGetSeconds(player.currentTime())
        if t.isFinite {
            progress = t
            updateActiveSegment()
        }
    }

    /// Provide transcript segment start times so activeSegmentIndex can be computed.
    func setSegmentTimestamps(_ timestamps: [TimeInterval]) {
        segmentTimestamps = timestamps
        updateActiveSegment()
    }

    /// Start playing a file at the given URL.
    func play(file: String, url: URL) {
        if playingFile == file, avPlayer != nil {
            togglePlayPause()
            return
        }

        stop()

        let playerItem = AVPlayerItem(url: url)
        playerItem.preferredForwardBufferDuration = 2
        let player = AVPlayer(playerItem: playerItem)
        player.automaticallyWaitsToMinimizeStalling = false

        avPlayer = player
        playingFile = file
        isPlaying = true

        // Get duration once asset is ready
        Task {
            if let dur = try? await playerItem.asset.load(.duration), dur.isNumeric {
                self.duration = CMTimeGetSeconds(dur)
            }
        }

        // End-of-playback
        endOfPlaybackObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.stop()
            }
        }

        player.rate = rate
    }

    func togglePlayPause() {
        guard let player = avPlayer else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.rate = rate
            isPlaying = true
        }
        syncProgressFromPlayer()
    }

    func stop() {
        if let obs = endOfPlaybackObserver {
            NotificationCenter.default.removeObserver(obs)
            endOfPlaybackObserver = nil
        }
        avPlayer?.pause()
        avPlayer = nil
        playingFile = nil
        isPlaying = false
        progress = 0
        duration = 0
        activeSegmentIndex = nil
        segmentTimestamps = []
    }

    func seek(to time: Double) {
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        avPlayer?.seek(to: cmTime)
        progress = time
        updateActiveSegment()
    }

    func setRate(_ newRate: Float) {
        rate = newRate
        guard let player = avPlayer else { return }
        if isPlaying {
            player.rate = newRate
        }
        syncProgressFromPlayer()
    }

    private func syncProgressFromPlayer() {
        guard let player = avPlayer else { return }
        let t = CMTimeGetSeconds(player.currentTime())
        if t.isFinite {
            progress = t
            updateActiveSegment()
        }
    }

    // MARK: - Active Segment

    private func updateActiveSegment() {
        guard !segmentTimestamps.isEmpty else {
            if activeSegmentIndex != nil { activeSegmentIndex = nil }
            return
        }
        var lo = 0, hi = segmentTimestamps.count - 1
        var result = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if segmentTimestamps[mid] <= progress {
                result = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        if activeSegmentIndex != result {
            activeSegmentIndex = result
        }
    }
}
