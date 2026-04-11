// © 2026 High Gain Design. All rights reserved.

import SwiftUI
import AVFoundation

@Observable
@MainActor
final class PlaybackState {
    var playingFile: String?
    var isPlaying: Bool = false
    var rate: Float = 1.0
    var progress: Double = 0
    var duration: Double = 0
    var activeSegmentIndex: Int?

    private(set) var avPlayer: AVPlayer?
    private var endOfPlaybackObserver: NSObjectProtocol?
    private var timeObserver: Any?
    private var boundaryObserver: Any?
    private var appNapActivity: NSObjectProtocol?

    var segmentTimestamps: [(start: Double, end: Double)] = [] {
        didSet { setupBoundaryObserver() }
    }

    /// Read current playback position directly from AVPlayer (for TimelineView-driven UI).
    var currentTime: Double {
        avPlayer?.currentTime().seconds ?? 0
    }

    static let speeds: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0]

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

        // Load duration
        Task {
            if let d = try? await playerItem.asset.load(.duration) {
                self.duration = d.seconds
            }
        }

        // Prevent App Nap during playback
        appNapActivity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiated,
            reason: "Audio playback"
        )

        // Periodic time observer — caches progress for seek-on-pause, etc.
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.progress = time.seconds
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
        setupBoundaryObserver()
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
        if let obs = timeObserver {
            avPlayer?.removeTimeObserver(obs)
            timeObserver = nil
        }
        if let obs = boundaryObserver {
            avPlayer?.removeTimeObserver(obs)
            boundaryObserver = nil
        }
        if let activity = appNapActivity {
            ProcessInfo.processInfo.endActivity(activity)
            appNapActivity = nil
        }
        avPlayer?.pause()
        avPlayer = nil
        playingFile = nil
        isPlaying = false
        progress = 0
        duration = 0
        activeSegmentIndex = nil
        // segmentTimestamps is managed by the view layer (set when transcript loads)
        // — don't clear it here, or play() → stop() destroys timestamps before
        // setupBoundaryObserver() can use them
    }

    func seek(to time: Double) {
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        avPlayer?.seek(to: cmTime)
        progress = time
        updateActiveSegment()
    }

    func setRate(_ newRate: Float) {
        rate = newRate
        if let player = avPlayer, isPlaying {
            player.rate = newRate
        }
    }

    private func setupBoundaryObserver() {
        // Remove old observer
        if let obs = boundaryObserver {
            avPlayer?.removeTimeObserver(obs)
            boundaryObserver = nil
        }

        guard let player = avPlayer, !segmentTimestamps.isEmpty else { return }

        let times = segmentTimestamps.map {
            NSValue(time: CMTime(seconds: $0.start, preferredTimescale: 600))
        }

        boundaryObserver = player.addBoundaryTimeObserver(
            forTimes: times, queue: .main
        ) { [weak self] in
            MainActor.assumeIsolated {
                self?.updateActiveSegment()
            }
        }

        // Set initial active segment for current position (boundary observer
        // only fires on future crossings, not retroactively)
        updateActiveSegment()
    }

    func updateActiveSegment() {
        guard !segmentTimestamps.isEmpty else {
            activeSegmentIndex = nil
            return
        }
        let t = currentTime
        activeSegmentIndex = segmentTimestamps.lastIndex { t >= $0.start && t < $0.end }
            ?? segmentTimestamps.lastIndex { t >= $0.start }
            ?? 0 // Before first segment — highlight it as "up next"
    }
}
