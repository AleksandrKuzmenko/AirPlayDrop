import AVFoundation
import os

private let logger = Logger(subsystem: "com.airplaydrop", category: "MetadataLoader")

struct MetadataLoader {

    @MainActor
    static func load(item: MediaItem) async {
        logger.debug("Loading metadata for '\(item.displayName)'")
        item.state = .loading

        let url = item.fileURL
        let asset = AVURLAsset(url: url)

        do {
            let isPlayable = try await asset.load(.isPlayable)
            guard isPlayable else {
                logger.warning("Asset not playable: \(item.displayName)")
                item.state = .unsupported
                return
            }

            let duration = try await asset.load(.duration)
            if duration.isValid && !duration.isIndefinite {
                item.duration = CMTimeGetSeconds(duration)
            }

            item.state = .ready
            logger.debug("Ready: '\(item.displayName)', duration=\(item.duration ?? 0, format: .fixed(precision: 1))s")
        } catch {
            logger.error("Failed to load '\(item.displayName)': \(error.localizedDescription)")
            item.state = .failed(error.localizedDescription)
        }
    }
}
