import Foundation
import Observation

// Shown by MainWindowView as an alert before any transcoding begins.
struct TranscodeRequest: Identifiable {
    let id = UUID()
    let item: MediaItem
    let outputURL: URL
}

// Internal queue entry — pairs a pending request with its suspended task continuation.
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

    /// Non-nil while an alert is visible asking the user to confirm transcoding.
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

            let task = Task { [weak self] in
                guard let self else { return }

                // 1. Load metadata
                await MetadataLoader.load(item: item)

                // 2. If not natively playable, transcode.
                if case .unsupported = item.state {
                    let outputURL = TranscodeService.outputURL(for: item.fileURL)

                    if FileManager.default.fileExists(atPath: outputURL.path) {
                        // Already transcoded from a previous session — reuse immediately.
                        item.transcodedURL = outputURL
                        item.state = .ready
                    } else {
                        // Phase 1: remux + audio-transcode are fast — run silently.
                        await TranscodeService.process(item: item, startingAt: 0, endBefore: 2)

                        // Phase 2: video re-encoding is slow — ask the user first.
                        if item.state != .ready {
                            let confirmed = await self.requestTranscodeConfirmation(
                                for: item, startingAt: 2, outputURL: outputURL)
                            if confirmed {
                                await TranscodeService.process(item: item, startingAt: 2)
                            }
                        }
                    }
                }

                // 3. Auto-select first ready item.
                if self.selectedID == nil, item.state == .ready {
                    self.selectedID = item.id
                }
            }
            processTasks[item.id] = task
        }
    }

    func remove(_ item: MediaItem) {
        processTasks[item.id]?.cancel()
        processTasks.removeValue(forKey: item.id)
        items.removeAll { $0.id == item.id }
        if selectedID == item.id {
            selectedID = items.first { $0.state == .ready }?.id
        }
    }

    func select(_ item: MediaItem) {
        selectedID = item.id
    }

    /// Called when AVPlayer reports a runtime failure — re-runs the transcode pipeline
    /// starting at `startingAt` to skip strategies already known not to work.
    func retranscode(_ item: MediaItem, startingAt: Int) {
        processTasks[item.id]?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            let outputURL = TranscodeService.outputURL(for: item.fileURL)

            // If startingAt is before video re-encoding, try audio-transcode silently first.
            if startingAt < 2 {
                await TranscodeService.process(item: item, startingAt: startingAt, endBefore: 2)
            }

            // If still not ready, we need video re-encoding — ask the user.
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

    // MARK: - Transcode confirmation

    /// Suspends the caller until the user confirms or cancels the alert.
    /// Queues requests so only one alert is shown at a time.
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

    /// Called by the view when the user taps Transcode or Cancel.
    func confirmTranscode(_ confirmed: Bool) {
        guard let current = transcodeQueue.first else { return }
        transcodeQueue.removeFirst()
        transcodeRequest = nil
        current.continuation.resume(returning: confirmed)

        // Show next queued request, if any.
        if let next = transcodeQueue.first {
            transcodeRequest = TranscodeRequest(item: next.item, outputURL: next.outputURL)
        }
    }
}
