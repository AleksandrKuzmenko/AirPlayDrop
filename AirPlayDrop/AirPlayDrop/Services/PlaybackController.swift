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

    private var endObserver: Any?
    private var statusObservation: NSKeyValueObservation?

    init() {
        player.allowsExternalPlayback = true
    }

    // Called when the user selects a different playlist row.
    func prepare(item: MediaItem?) {
        guard loadedItem?.id != item?.id else { return }
        stopInternal()
        loadedItem = item
        logger.debug("Prepared for: \(item?.displayName ?? "none")")
    }

    func play() {
        guard let item = loadedItem, item.state == .ready else {
            logger.warning("play() called with no ready item")
            return
        }

        // Build a fresh AVPlayerItem each time we press Play from stopped state.
        if player.currentItem == nil {
            let playerItem = AVPlayerItem(url: item.fileURL)
            player.replaceCurrentItem(with: playerItem)
            observeEnd(of: playerItem)
        }

        player.play()
        isPlaying = true
        logger.debug("Playback started: '\(item.displayName)'")
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
        removeEndObserver()
    }

    private func observeEnd(of playerItem: AVPlayerItem) {
        removeEndObserver()
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleEnd()
            }
        }
    }

    private func handleEnd() {
        logger.debug("Playback reached end of item")
        player.seek(to: .zero)
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        removeEndObserver()
    }

    private func removeEndObserver() {
        if let obs = endObserver {
            NotificationCenter.default.removeObserver(obs)
            endObserver = nil
        }
    }
}
