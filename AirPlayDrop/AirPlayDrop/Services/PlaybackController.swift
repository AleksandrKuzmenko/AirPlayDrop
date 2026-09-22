import AVFoundation
import CoreGraphics
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
    private(set) var resumeProposal: PlaybackResumeProposal?
    var hasResumableProgress: Bool { resumeProposal != nil }
    var pendingResume: PlaybackResumeProposal? { resumeProposal }
    private(set) var scrubPreview: CGImage?
    var volume: Float {
        get { player.volume }
        set { player.volume = max(0, min(1, newValue)) }
    }

    var onPlaybackFailure: ((MediaItem) -> Void)?
    var onVideoRenderFailure: ((MediaItem) -> Void)?
    var onAirPlayCompatibilityRequired: ((MediaItem) -> Void)?
    var onEnded: (() -> Void)?

    private let historyStore: PlaybackHistoryStoring
    private let thumbnailProvider: ThumbnailProvider
    private let now: @Sendable () -> Date
    private var lastHistoryWriteAt: Date?
    private var resumeWasEvaluated = false
    private var playbackRequested = false
    private var resumeShouldContinuePlaying = false
    private var thumbnailTask: Task<Void, Never>?
    private var thumbnailGeneration = 0
    private var requestedThumbnailBucket: Int?

    private var endObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var externalPlaybackObservation: NSKeyValueObservation?
    private var durationObservation: NSKeyValueObservation?
    private var timeObserver: Any?

    init(historyStore: PlaybackHistoryStoring = PlaybackHistoryStore(),
         thumbnailProvider: ThumbnailProvider = ThumbnailProvider(),
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.historyStore = historyStore
        self.thumbnailProvider = thumbnailProvider
        self.now = now
        player.allowsExternalPlayback = true
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            let playing = p.timeControlStatus == .playing
            Task { @MainActor [weak self] in self?.isPlaying = playing }
        }
        externalPlaybackObservation = player.observe(\.isExternalPlaybackActive, options: [.new, .initial]) { [weak self] p, _ in
            let active = p.isExternalPlaybackActive
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isExternalPlaybackActive = active
                logger.debug("isExternalPlaybackActive=\(active)")
                if active {
                    self.requestAirPlayConversionIfNeeded()
                }
            }
        }
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            let seconds = CMTimeGetSeconds(time)
            Task { @MainActor [weak self] in
                guard let self, seconds.isFinite else { return }
                self.currentTime = seconds
                self.scheduleHistorySave()
            }
        }
    }

    func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        let t = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = seconds
    }

    func resume() {
        guard let proposal = resumeProposal else { return }
        let shouldContinue = resumeShouldContinuePlaying
        seek(to: proposal.position)
        resumeProposal = nil
        resumeShouldContinuePlaying = false
        if shouldContinue {
            playbackRequested = true
            player.play()
        }
    }

    func resumePlayback() { resume() }

    func startOver() {
        let shouldContinue = resumeShouldContinuePlaying
        if let item = loadedItem { historyStore.clear(sourceURL: item.fileURL) }
        resumeProposal = nil
        resumeShouldContinuePlaying = false
        seek(to: 0)
        if shouldContinue {
            playbackRequested = true
            player.play()
        }
    }

    func flushHistory() { persistHistory(force: true) }

    func requestThumbnail(at seconds: Double) {
        guard let item = loadedItem,
              let bucket = ThumbnailProvider.quantizedBucket(seconds),
              requestedThumbnailBucket != bucket else { return }
        requestedThumbnailBucket = bucket
        thumbnailTask?.cancel()
        thumbnailGeneration += 1
        let generation = thumbnailGeneration
        let itemID = item.id
        let url = item.playbackURL
        let duration = duration
        thumbnailTask = Task { @MainActor [weak self] in
            guard let image = await self?.thumbnailProvider.image(for: url, at: seconds, duration: duration),
                  let self,
                  self.thumbnailGeneration == generation,
                  self.loadedItem?.id == itemID else { return }
            self.scrubPreview = image
        }
    }

    func clearThumbnail() {
        thumbnailTask?.cancel()
        thumbnailTask = nil
        thumbnailGeneration += 1
        requestedThumbnailBucket = nil
        scrubPreview = nil
    }

    // MARK: - Selection

    func prepare(item: MediaItem?) {
        guard loadedItem?.id != item?.id else { return }
        teardown()
        loadedItem = item
        clearThumbnail()
        resumeProposal = nil
        resumeWasEvaluated = false
        lastHistoryWriteAt = nil
        logger.debug("Prepared: \(item?.displayName ?? "none")")
    }

    // MARK: - Transport

    func play() {
        guard let item = loadedItem, item.state == .ready else { return }
        playbackRequested = true
        if resumeProposal != nil { return }
        if isExternalPlaybackActive, item.needsAirPlayTranscode {
            requestAirPlayConversionIfNeeded()
            return
        }
        if player.currentItem == nil {
            let playerItem = AVPlayerItem(url: item.playbackURL)
            player.replaceCurrentItem(with: playerItem)
            observeEnd(of: playerItem)
            observeStatus(of: playerItem, mediaItem: item)
            observeDuration(of: playerItem)
        }
        player.play()
    }

    func pause() {
        playbackRequested = false
        resumeShouldContinuePlaying = false
        player.pause()
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    func stop() {
        playbackRequested = false
        teardown()
    }

    // MARK: - Private

    private func requestAirPlayConversionIfNeeded() {
        guard let item = loadedItem,
              item.state == .ready,
              item.needsAirPlayTranscode else { return }

        logger.notice("AirPlay conversion required for '\(item.displayName)'")
        persistHistory(force: true)
        player.pause()
        player.replaceCurrentItem(with: nil)
        removeObservers()
        currentTime = 0
        duration = 0
        resumeProposal = nil
        onAirPlayCompatibilityRequired?(item)
    }

    private func teardown() {
        persistHistory(force: true)
        player.pause()
        player.replaceCurrentItem(with: nil)
        removeObservers()
        currentTime = 0
        duration = 0
        resumeProposal = nil
    }

    private func observeEnd(of playerItem: AVPlayerItem) {
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let item = self.loadedItem { self.historyStore.clear(sourceURL: item.fileURL) }
                self.resumeProposal = nil
                self.resumeShouldContinuePlaying = false
                self.playbackRequested = false
                self.player.seek(to: .zero)
                self.currentTime = 0
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
                self.evaluateResumeProposal()
            }
        }
    }

    private func evaluateResumeProposal() {
        guard !resumeWasEvaluated, let item = loadedItem else { return }
        resumeWasEvaluated = true
        guard let entry = historyStore.entry(for: item.fileURL),
              PlaybackHistoryStore.isEligible(position: entry.position, duration: duration) else { return }
        resumeShouldContinuePlaying = playbackRequested
        player.pause()
        resumeProposal = PlaybackResumeProposal(position: entry.position, duration: duration)
    }

    private func scheduleHistorySave() {
        guard isPlaying else { return }
        // The 0.25-second observer only updates memory. Store access is
        // deferred so UserDefaults work is outside that callback.
        Task { @MainActor [weak self] in self?.persistHistory(force: false) }
    }

    private func persistHistory(force: Bool) {
        guard let item = loadedItem,
              currentTime.isFinite, duration.isFinite, duration > 0 else { return }
        // Do not replace a valid stored position with time zero while the user
        // is deciding whether to resume.
        guard resumeProposal == nil else { return }
        let date = now()
        if !force, let lastHistoryWriteAt,
           date.timeIntervalSince(lastHistoryWriteAt) < 5 { return }
        if currentTime >= 30, duration - currentTime < 60 {
            historyStore.clear(sourceURL: item.fileURL)
            lastHistoryWriteAt = date
            return
        }
        guard PlaybackHistoryStore.isEligible(position: currentTime, duration: duration) else { return }
        historyStore.save(sourceURL: item.fileURL, position: currentTime, duration: duration, at: date)
        lastHistoryWriteAt = date
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
