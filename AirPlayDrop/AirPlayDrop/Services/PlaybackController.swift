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

    /// Called when AVPlayer reports a fatal item failure (e.g. unsupported audio codec).
    /// PlaylistStore wires this to `store.retranscode(_:startingAt:)` with index 1.
    var onPlaybackFailure: ((MediaItem) -> Void)?

    /// Called when AVPlayer can decode the item but produces no video image (e.g. unsupported
    /// HEVC profile). PlaylistStore wires this to `store.retranscode(_:startingAt:)` with index 2.
    var onVideoRenderFailure: ((MediaItem) -> Void)?

    private var endObserver: Any?
    private var statusObservation: NSKeyValueObservation?

    init() {
        player.allowsExternalPlayback = true
    }

    // MARK: - Selection

    /// Called whenever the playlist selection changes.
    func prepare(item: MediaItem?) {
        guard loadedItem?.id != item?.id else { return }
        stopInternal()
        loadedItem = item
        logger.debug("Prepared for: \(item?.displayName ?? "none")")
    }

    // MARK: - Transport

    func play() {
        guard let item = loadedItem, item.state == .ready else {
            logger.warning("play() called with no ready item")
            return
        }

        if player.currentItem == nil {
            // Prefer the transcoded copy when available.
            let playerItem = AVPlayerItem(url: item.playbackURL)
            player.replaceCurrentItem(with: playerItem)
            observeEnd(of: playerItem)
            observeStatus(of: playerItem, mediaItem: item)
        }

        player.play()
        isPlaying = true
        logger.debug("Playback started: '\(item.displayName)' url=\(item.playbackURL.lastPathComponent)")
    }

    func stop() {
        stopInternal()
        logger.debug("Playback stopped by user")
    }

    // MARK: - Private

    private func stopInternal() {
        player.pause()
        player.seek(to: .zero)
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        removeObservers()
    }

    private func observeEnd(of playerItem: AVPlayerItem) {
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleEnd() }
        }
    }

    private func observeStatus(of playerItem: AVPlayerItem, mediaItem: MediaItem) {
        statusObservation?.invalidate()
        statusObservation = playerItem.observe(\.status, options: [.new]) { item, _ in
            switch item.status {
            case .failed:
                let desc = item.error?.localizedDescription ?? "Playback pipeline failed"
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    logger.error("AVPlayerItem failed: \(desc)")
                    self.isPlaying = false
                    self.player.replaceCurrentItem(with: nil)
                    mediaItem.state = .failed(desc)
                    self.onPlaybackFailure?(mediaItem)
                }

            case .readyToPlay:
                // Detect audio-only output when a video track is present — the video codec
                // decoded successfully from AVFoundation's perspective but VideoToolbox can't
                // render frames (e.g. 10-bit HEVC on unsupported hardware/profile).
                let hasVideo = item.tracks.contains { $0.assetTrack?.mediaType == .video }
                let size = item.presentationSize
                guard hasVideo && size == .zero else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    logger.error("AVPlayerItem: video track present but no image (presentationSize=zero) — triggering full transcode")
                    self.isPlaying = false
                    self.player.replaceCurrentItem(with: nil)
                    mediaItem.state = .failed("Video codec not renderable; re-encoding to H.264")
                    self.onVideoRenderFailure?(mediaItem)
                }

            default:
                break
            }
        }
    }

    private func handleEnd() {
        logger.debug("Playback reached end of item")
        player.seek(to: .zero)
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        removeObservers()
    }

    private func removeObservers() {
        if let obs = endObserver {
            NotificationCenter.default.removeObserver(obs)
            endObserver = nil
        }
        statusObservation?.invalidate()
        statusObservation = nil
    }
}
