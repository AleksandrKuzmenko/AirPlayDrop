import AVFoundation
import Observation
import os

private let logger = Logger(subsystem: "com.airplaydrop", category: "PlaybackController")

@Observable
@MainActor
final class PlaybackController {

    let player = AVPlayer()
    private(set) var isPlaying = false
    private(set) var loadedItem: MediaItem?
    private(set) var isExternalPlaybackActive = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    var volume: Float {
        get { player.volume }
        set { player.volume = max(0, min(1, newValue)) }
    }

    var onPlaybackFailure: ((MediaItem) -> Void)?
    var onVideoRenderFailure: ((MediaItem) -> Void)?
    var onEnded: (() -> Void)?

    private var endObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var externalPlaybackObservation: NSKeyValueObservation?
    private var durationObservation: NSKeyValueObservation?
    private var timeObserver: Any?

    init() {
        player.allowsExternalPlayback = true
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            let playing = p.timeControlStatus == .playing
            Task { @MainActor [weak self] in self?.isPlaying = playing }
        }
        externalPlaybackObservation = player.observe(\.isExternalPlaybackActive, options: [.new, .initial]) { [weak self] p, _ in
            let active = p.isExternalPlaybackActive
            Task { @MainActor [weak self] in
                self?.isExternalPlaybackActive = active
                logger.debug("isExternalPlaybackActive=\(active)")
            }
        }
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            let seconds = CMTimeGetSeconds(time)
            Task { @MainActor [weak self] in
                guard let self, seconds.isFinite else { return }
                self.currentTime = seconds
            }
        }
    }

    func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        let t = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = seconds
    }

    // MARK: - Selection

    func prepare(item: MediaItem?) {
        guard loadedItem?.id != item?.id else { return }
        teardown()
        loadedItem = item
        logger.debug("Prepared: \(item?.displayName ?? "none")")
    }

    // MARK: - Transport

    func play() {
        guard let item = loadedItem, item.state == .ready else { return }
        if player.currentItem == nil {
            let playerItem = AVPlayerItem(url: item.playbackURL)
            player.replaceCurrentItem(with: playerItem)
            observeEnd(of: playerItem)
            observeStatus(of: playerItem, mediaItem: item)
            observeDuration(of: playerItem)
        }
        player.play()
    }

    func pause() { player.pause() }

    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    func stop() {
        teardown()
    }

    // MARK: - Private

    private func teardown() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        removeObservers()
        currentTime = 0
        duration = 0
    }

    private func observeEnd(of playerItem: AVPlayerItem) {
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.player.seek(to: .zero)
                self.onEnded?()
            }
        }
    }

    private func observeStatus(of playerItem: AVPlayerItem, mediaItem: MediaItem) {
        statusObservation?.invalidate()
        statusObservation = playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            Task { @MainActor [weak self] in
                await self?.handleStatus(status, item: item, mediaItem: mediaItem)
            }
        }
    }

    private func handleStatus(_ status: AVPlayerItem.Status, item: AVPlayerItem, mediaItem: MediaItem) async {
        switch status {
        case .failed:
            let desc = item.error?.localizedDescription ?? "Playback pipeline failed"
            logger.error("AVPlayerItem failed: \(desc)")
            player.replaceCurrentItem(with: nil)
            mediaItem.state = .failed(desc)
            onPlaybackFailure?(mediaItem)

        case .readyToPlay:
            // When the player is streaming to AirPlay, no local video surface exists,
            // so `presentationSize` legitimately stays zero. Skip the render check.
            if player.isExternalPlaybackActive { return }

            let videoTracks = (try? await item.asset.loadTracks(withMediaType: .video)) ?? []
            guard !videoTracks.isEmpty else { return }
            for _ in 0..<10 {
                if item.presentationSize != .zero { return }
                if player.isExternalPlaybackActive { return }
                try? await Task.sleep(nanoseconds: 150_000_000)
                if Task.isCancelled { return }
            }
            guard item.presentationSize == .zero,
                  !player.isExternalPlaybackActive,
                  player.currentItem === item else { return }
            logger.error("Video track present but no image — triggering full transcode")
            player.replaceCurrentItem(with: nil)
            mediaItem.state = .failed("Video codec not renderable; re-encoding to H.264")
            onVideoRenderFailure?(mediaItem)

        default:
            break
        }
    }

    private func observeDuration(of playerItem: AVPlayerItem) {
        durationObservation?.invalidate()
        durationObservation = playerItem.observe(\.duration, options: [.new, .initial]) { [weak self] item, _ in
            let d = CMTimeGetSeconds(item.duration)
            Task { @MainActor [weak self] in
                guard let self, d.isFinite, d > 0 else { return }
                self.duration = d
            }
        }
    }

    private func removeObservers() {
        if let obs = endObserver {
            NotificationCenter.default.removeObserver(obs)
            endObserver = nil
        }
        statusObservation?.invalidate()
        statusObservation = nil
        durationObservation?.invalidate()
        durationObservation = nil
    }
}
