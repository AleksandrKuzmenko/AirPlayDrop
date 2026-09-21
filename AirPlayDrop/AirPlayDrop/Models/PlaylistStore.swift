import AVFoundation
import Foundation
import Observation

struct JobTokenRegistry {
    private var tokens: [UUID: UUID] = [:]

    mutating func begin(itemID: UUID) -> UUID {
        let token = UUID()
        tokens[itemID] = token
        return token
    }

    mutating func invalidate(itemID: UUID) { tokens.removeValue(forKey: itemID) }
    mutating func invalidateAll() { tokens.removeAll() }
    func isCurrent(_ token: UUID, itemID: UUID) -> Bool { tokens[itemID] == token }
}

@Observable
@MainActor
final class PlaylistStore {
    var items: [MediaItem] = []
    var selectedID: UUID?

    var selectedItem: MediaItem? {
        guard let selectedID else { return nil }
        return items.first { $0.id == selectedID }
    }

    private var processTasks: [UUID: Task<Void, Never>] = [:]
    private var jobTokens = JobTokenRegistry()

    func add(urls: [URL]) {
        for url in urls where !items.contains(where: { $0.fileURL.standardizedFileURL == url.standardizedFileURL }) {
            let item = MediaItem(fileURL: url)
            items.append(item)
            launchMetadataJob(for: item)
        }
    }

    func remove(_ item: MediaItem) {
        cancel(item)
        items.removeAll { $0.id == item.id }
        if selectedID == item.id { selectedID = items.first { $0.state == .ready }?.id }
    }

    func removeAll() {
        processTasks.values.forEach { $0.cancel() }
        processTasks.removeAll()
        jobTokens.invalidateAll()
        items.removeAll()
        selectedID = nil
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
    }

    func select(_ item: MediaItem) { selectedID = item.id }

    func nextReadyItem(after item: MediaItem) -> MediaItem? {
        guard let index = items.firstIndex(where: { $0.id == item.id }), index + 1 < items.endIndex else { return nil }
        return items[(index + 1)...].first { $0.state == .ready }
    }

    func retry(_ item: MediaItem) {
        item.transcodedURL = nil
        item.isAirPlayPrepared = false
        item.preparationReason = nil
        launchMetadataJob(for: item)
    }

    func prepare(_ item: MediaItem, for intent: PlaybackIntent) {
        let fallback: MediaItemState = item.transcodedURL != nil || item.state == .ready ? .ready : .unsupported
        launchPreparationJob(for: item, intent: intent, fallbackState: fallback)
    }

    func forceTranscode(_ item: MediaItem) { prepare(item, for: .airPlay) }

    func retranscode(_ item: MediaItem, for intent: PlaybackIntent) {
        item.transcodedURL = nil
        item.isAirPlayPrepared = false
        launchPreparationJob(for: item, intent: intent, fallbackState: .failed("Playback failed; conversion was cancelled."))
    }

    func cancel(_ item: MediaItem) {
        processTasks[item.id]?.cancel()
        processTasks.removeValue(forKey: item.id)
        jobTokens.invalidate(itemID: item.id)
        if case .transcoding = item.state {
            item.state = item.transcodedURL == nil ? .unsupported : .ready
            item.preparationReason = "Preparation cancelled."
        }
    }

    func chooseAudio(_ trackID: Int?, for item: MediaItem) {
        item.trackSelection.audioID = trackID
        invalidatePreparedArtifact(item)
    }

    func chooseSubtitle(_ trackID: Int?, for item: MediaItem) {
        item.trackSelection.subtitleID = trackID
        item.trackSelection.subtitlePolicy = trackID == nil ? .omit : .includeSelected
        invalidatePreparedArtifact(item)
    }

    private func invalidatePreparedArtifact(_ item: MediaItem) {
        if item.transcodedURL != nil {
            item.transcodedURL = nil
            item.isAirPlayPrepared = false
            item.preparationReason = "Track selection changed; prepare the video again."
        }
    }

    private func beginJob(for item: MediaItem) -> (token: UUID, previous: Task<Void, Never>?) {
        let previous = processTasks[item.id]
        previous?.cancel()
        return (jobTokens.begin(itemID: item.id), previous)
    }

    private func isCurrent(_ token: UUID, for item: MediaItem) -> Bool {
        jobTokens.isCurrent(token, itemID: item.id) && items.contains { $0.id == item.id }
    }

    private func finish(_ token: UUID, for item: MediaItem) {
        guard isCurrent(token, for: item) else { return }
        processTasks.removeValue(forKey: item.id)
        jobTokens.invalidate(itemID: item.id)
    }

    private func launchMetadataJob(for item: MediaItem) {
        let job = beginJob(for: item)
        let token = job.token
        item.state = .loading
        processTasks[item.id] = Task { [weak self, weak item] in
            if let previous = job.previous { await previous.value }
            guard let self, let item else { return }
            await MetadataLoader.load(item: item)
            guard self.isCurrent(token, for: item), !Task.isCancelled else { return }

            if let installation = FFmpegLocator.locate(),
               let info = try? await FFprobeService.probe(item.fileURL, using: installation) {
                guard self.isCurrent(token, for: item), !Task.isCancelled else { return }
                item.mediaInfo = info
                item.duration = item.duration ?? info.duration
                item.trackSelection = FFprobeService.defaultSelection(from: info)
            }

            if case .unsupported = item.state {
                self.finish(token, for: item)
                self.launchPreparationJob(for: item, intent: .local, fallbackState: .unsupported)
                return
            }
            if item.state == .ready {
                item.isAirPlayPrepared = await VideoFormatProbe.isAirPlayPrepared(AVURLAsset(url: item.playbackURL))
                if self.selectedID == nil { self.selectedID = item.id }
            }
            self.finish(token, for: item)
        }
    }

    private func launchPreparationJob(for item: MediaItem, intent: PlaybackIntent, fallbackState: MediaItemState) {
        let job = beginJob(for: item)
        let token = job.token
        item.playbackIntent = intent
        item.preparationReason = intent == .airPlay ? "Inspecting Apple TV compatibility…" : "Inspecting media compatibility…"
        item.state = .transcoding(0)

        processTasks[item.id] = Task { [weak self, weak item] in
            if let previous = job.previous { await previous.value }
            guard let self, let item else { return }
            do {
                guard let installation = FFmpegLocator.locate() else { throw TranscodeError.ffmpegNotFound }
                let info: MediaInfo
                if let existing = item.mediaInfo { info = existing }
                else { info = try await FFprobeService.probe(item.fileURL, using: installation) }
                guard self.isCurrent(token, for: item) else { return }
                item.mediaInfo = info
                if item.trackSelection.audioID == nil && info.hasAudio {
                    item.trackSelection = FFprobeService.defaultSelection(from: info)
                }
                let plan = TranscodePlanner.plan(info: info, intent: intent,
                    selectedAudioID: item.trackSelection.audioID)
                item.preparationReason = plan.reason

                var cachedURL: URL?
                for candidate in OutputReservation.existingArtifacts(for: item.fileURL) {
                    let validation = await MediaArtifactValidator.validateCached(candidate, source: item.fileURL,
                        expectedSelectedAudioID: item.trackSelection.audioID)
                    guard self.isCurrent(token, for: item), !Task.isCancelled else { return }
                    if validation.isValid { cachedURL = candidate; break }
                }
                if let cachedURL {
                    item.transcodedURL = cachedURL
                    item.isAirPlayPrepared = intent == .airPlay
                    item.preparationReason = "Reused a validated prepared copy."
                    item.state = .ready
                } else {
                    let artifact = try await TranscodeService.prepare(input: item.fileURL, info: info,
                        selection: item.trackSelection, intent: intent) { [weak self, weak item] progress in
                            Task { @MainActor in
                                guard let self, let item, self.isCurrent(token, for: item) else { return }
                                if case .transcoding(let old) = item.state {
                                    item.state = .transcoding(max(old, progress))
                                }
                            }
                        }
                    guard self.isCurrent(token, for: item), !Task.isCancelled else { return }
                    item.transcodedURL = artifact.url == item.fileURL ? nil : artifact.url
                    item.isAirPlayPrepared = artifact.isAirPlayPrepared
                    item.preparationReason = artifact.reason
                    item.state = .ready
                }
                if self.selectedID == nil { self.selectedID = item.id }
            } catch is CancellationError {
                guard self.isCurrent(token, for: item) else { return }
                item.state = fallbackState
                item.preparationReason = "Preparation cancelled."
            } catch {
                guard self.isCurrent(token, for: item) else { return }
                item.state = .failed(error.localizedDescription)
                item.preparationReason = nil
            }
            self.finish(token, for: item)
        }
    }
}
