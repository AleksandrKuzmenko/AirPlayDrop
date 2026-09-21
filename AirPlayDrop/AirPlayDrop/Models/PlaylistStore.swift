import Foundation
import Observation
import AVFoundation

struct TranscodeRequest: Identifiable {
    let id = UUID()
    let item: MediaItem
    let outputURL: URL
}

private struct PendingTranscode {
    let item: MediaItem
    let startingAt: Int
    let outputURL: URL
    let continuation: CheckedContinuation<Bool, Never>
}

@Observable
@MainActor
final class PlaylistStore {
    var items: [MediaItem] = []
    var selectedID: UUID?
    var transcodeRequest: TranscodeRequest?

    var selectedItem: MediaItem? {
        guard let id = selectedID else { return nil }
        return items.first { $0.id == id }
    }

    private var processTasks: [UUID: Task<Void, Never>] = [:]
    private var transcodeQueue: [PendingTranscode] = []

    // MARK: - Mutations

    func add(urls: [URL]) {
        for url in urls {
            guard !items.contains(where: {
                $0.fileURL.standardizedFileURL == url.standardizedFileURL
            }) else { continue }

            let item = MediaItem(fileURL: url)
            items.append(item)
            processTasks[item.id] = processItem(item)
        }
    }

    func remove(_ item: MediaItem) {
        processTasks[item.id]?.cancel()
        processTasks.removeValue(forKey: item.id)
        cancelPendingTranscode(for: item.id)
        items.removeAll { $0.id == item.id }
        if selectedID == item.id {
            selectedID = items.first { $0.state == .ready }?.id
        }
    }

    func removeAll() {
        for (_, task) in processTasks { task.cancel() }
        processTasks.removeAll()
        for pending in transcodeQueue { pending.continuation.resume(returning: false) }
        transcodeQueue.removeAll()
        transcodeRequest = nil
        items.removeAll()
        selectedID = nil
    }

    /// Resolves any queued transcode-confirmation continuations for this item with `false`,
    /// and advances the visible alert to the next queued request (or dismisses it).
    private func cancelPendingTranscode(for itemID: UUID) {
        let wasFirstForThisItem = transcodeQueue.first?.item.id == itemID
        let (pendingForItem, rest) = transcodeQueue.reduce(into: ([PendingTranscode](), [PendingTranscode]())) { acc, p in
            if p.item.id == itemID { acc.0.append(p) } else { acc.1.append(p) }
        }
        transcodeQueue = rest
        for p in pendingForItem { p.continuation.resume(returning: false) }
        if wasFirstForThisItem {
            transcodeRequest = transcodeQueue.first.map {
                TranscodeRequest(item: $0.item, outputURL: $0.outputURL)
            }
        }
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
    }

    func select(_ item: MediaItem) {
        selectedID = item.id
    }

    func nextReadyItem(after item: MediaItem) -> MediaItem? {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return nil }
        return items[(idx + 1)...].first { $0.state == .ready }
    }

    /// Called when AVPlayer reports a runtime failure — re-runs the transcode pipeline
    /// starting at `startingAt` to skip strategies already known not to work.
    func retranscode(_ item: MediaItem, startingAt: Int) {
        processTasks[item.id]?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            let outputURL = TranscodeService.outputURL(for: item.fileURL)

            if startingAt < 2 {
                await TranscodeService.process(item: item, startingAt: startingAt, endBefore: 2)
            }

            if item.state != .ready {
                let confirmed = await self.requestTranscodeConfirmation(
                    for: item, startingAt: 2, outputURL: outputURL)
                if confirmed {
                    await TranscodeService.process(item: item, startingAt: 2)
                }
            }

            if self.selectedID == nil, item.state == .ready {
                self.selectedID = item.id
            }
        }
        processTasks[item.id] = task
    }

    /// Wipes any cached transcode output and re-runs the full pipeline from scratch.
    func retry(_ item: MediaItem) {
        processTasks[item.id]?.cancel()
        item.transcodedURL = nil
        item.isAirPlayPrepared = false
        item.state = .idle
        processTasks[item.id] = processItem(item)
    }

    /// Forces a full H.264/AAC re-encode even if the source is natively playable.
    /// Use when AirPlay external playback rejects the native codec.
    func forceTranscode(_ item: MediaItem) {
        processTasks[item.id]?.cancel()
        item.transcodedURL = nil
        item.isAirPlayPrepared = false
        item.state = .idle
        processTasks[item.id] = Task { [weak self] in
            guard let self else { return }
            let outputURL = TranscodeService.outputURL(for: item.fileURL)
            let confirmed = await self.requestTranscodeConfirmation(
                for: item, startingAt: 2, outputURL: outputURL)
            if confirmed {
                await TranscodeService.processForAirPlay(item: item)
                if item.state == .ready {
                    let asset = AVURLAsset(url: item.playbackURL)
                    item.formatFlags = await VideoFormatProbe.inspect(asset)
                }
            } else {
                item.state = .ready
            }
        }
    }

    // MARK: - Processing pipeline

    private func processItem(_ item: MediaItem) -> Task<Void, Never> {
        Task { [weak self] in
            guard let self else { return }

            await MetadataLoader.load(item: item)

            if case .unsupported = item.state {
                let outputURL = TranscodeService.outputURL(for: item.fileURL)

                let cached = await MediaArtifactValidator.validateCached(outputURL, source: item.fileURL)
                if cached.isValid {
                    item.transcodedURL = outputURL
                    item.state = .ready
                } else {
                    await TranscodeService.process(item: item, startingAt: 0, endBefore: 2)

                    if item.state != .ready {
                        let confirmed = await self.requestTranscodeConfirmation(
                            for: item, startingAt: 2, outputURL: outputURL)
                        if confirmed {
                            await TranscodeService.process(item: item, startingAt: 2)
                        }
                    }
                }
            }

            // Re-probe the playback URL — remux preserves HDR/DV streams from the source,
            // so the flags need to reflect the file AVPlayer is actually going to hand to AirPlay.
            if item.state == .ready {
                let asset = AVURLAsset(url: item.playbackURL)
                item.formatFlags = await VideoFormatProbe.inspect(asset)
                item.isAirPlayPrepared = await VideoFormatProbe.isAirPlayPrepared(asset)
            }

            if self.selectedID == nil, item.state == .ready {
                self.selectedID = item.id
            }
        }
    }

    // MARK: - Transcode confirmation

    private func requestTranscodeConfirmation(
        for item: MediaItem,
        startingAt: Int,
        outputURL: URL
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            let pending = PendingTranscode(
                item: item, startingAt: startingAt,
                outputURL: outputURL, continuation: continuation)
            transcodeQueue.append(pending)
            if transcodeQueue.count == 1 {
                transcodeRequest = TranscodeRequest(item: item, outputURL: outputURL)
            }
        }
    }

    func confirmTranscode(_ confirmed: Bool) {
        guard let current = transcodeQueue.first else { return }
        transcodeQueue.removeFirst()
        transcodeRequest = nil
        current.continuation.resume(returning: confirmed)

        if let next = transcodeQueue.first {
            transcodeRequest = TranscodeRequest(item: next.item, outputURL: next.outputURL)
        }
    }
}
