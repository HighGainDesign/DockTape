import SwiftUI
import AVFoundation

/// Simple audio playback state — play, pause, stop, and speed control.
///
/// Progress tracking and transcript highlighting are intentionally disabled.
/// macOS App Nap throttles all timer mechanisms (TimelineView, periodic time
/// observers, Timer) making reliable progress updates infeasible without a
/// deeper architectural fix. The scrubber and highlighting will be revisited
/// in a future release.
@Observable
@MainActor
final class PlaybackState {
    var playingFile: String?
    var isPlaying: Bool = false
    var rate: Float = 1.0

    // Retained for API compatibility but not actively updated.
    var progress: Double = 0
    var duration: Double = 0
    var activeSegmentIndex: Int?

    private var avPlayer: AVPlayer?
    private var endOfPlaybackObserver: NSObjectProtocol?

    static let speeds: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0]

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
    }

    func seek(to time: Double) {
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        avPlayer?.seek(to: cmTime)
    }

    func setRate(_ newRate: Float) {
        rate = newRate
        if let player = avPlayer, isPlaying {
            player.rate = newRate
        }
    }
}
