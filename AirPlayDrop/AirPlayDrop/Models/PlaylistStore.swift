import Foundation
import Observation

@Observable
@MainActor
final class PlaylistStore {
    var items: [MediaItem] = []
    var selectedID: UUID?

    var selectedItem: MediaItem? {
        guard let id = selectedID else { return nil }
        return items.first { $0.id == id }
    }

    /// Tracks the in-flight Task for each item (metadata load + optional transcode).
    private var processTasks: [UUID: Task<Void, Never>] = [:]

    // MARK: - Mutations

    func add(urls: [URL]) {
        for url in urls {
            guard !items.contains(where: {
                $0.fileURL.standardizedFileURL == url.standardizedFileURL
            }) else { continue }

            let item = MediaItem(fileURL: url)
            items.append(item)

            let task = Task { [weak self] in
                // 1. Load metadata (sets state → .ready / .unsupported / .failed)
                await MetadataLoader.load(item: item)

                // 2. If AVFoundation can't play it natively, try FFmpeg.
                if case .unsupported = item.state {
                    await TranscodeService.process(item: item)
                }

                // 3. Auto-select the first item that becomes ready.
                if self?.selectedID == nil, item.state == .ready {
                    self?.selectedID = item.id
                }
            }
            processTasks[item.id] = task
        }
    }

    func remove(_ item: MediaItem) {
        // Cancel any in-flight work for this item.
        processTasks[item.id]?.cancel()
        processTasks.removeValue(forKey: item.id)

        // Clean up the transcoded temp file asynchronously.
        if let url = item.transcodedURL {
            Task.detached { try? FileManager.default.removeItem(at: url) }
        }

        items.removeAll { $0.id == item.id }

        if selectedID == item.id {
            selectedID = items.first { $0.state == .ready }?.id
        }
    }

    func select(_ item: MediaItem) {
        selectedID = item.id
    }

    /// Called when AVPlayer reports a runtime failure — re-runs the transcode pipeline.
    func retranscode(_ item: MediaItem) {
        processTasks[item.id]?.cancel()
        let task = Task { [weak self] in
            await TranscodeService.process(item: item)
            if self?.selectedID == nil, item.state == .ready {
                self?.selectedID = item.id
            }
        }
        processTasks[item.id] = task
    }
}
