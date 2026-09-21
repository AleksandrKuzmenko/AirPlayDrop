import AVFoundation
import os

private let logger = Logger(subsystem: "com.airplaydrop", category: "MetadataLoader")

struct MetadataLoader {

    @MainActor
    static func load(item: MediaItem) async {
        logger.debug("Loading metadata for '\(item.displayName)'")
        item.state = .loading

        let asset = AVURLAsset(url: item.fileURL)

        do {
            // Best-effort duration load regardless of playability — useful for
            // transcode progress reporting on files AVFoundation can't play.
            if let duration = try? await asset.load(.duration),
               duration.isValid && !duration.isIndefinite {
                guard !Task.isCancelled else { throw CancellationError() }
                item.duration = CMTimeGetSeconds(duration)
            }

            let isPlayable = try await asset.load(.isPlayable)
            guard !Task.isCancelled else { throw CancellationError() }
            guard isPlayable else {
                logger.warning("Asset not playable: \(item.displayName)")
                item.state = .unsupported
                return
            }

            let flags = await VideoFormatProbe.inspect(asset)
            guard !Task.isCancelled else { throw CancellationError() }
            item.formatFlags = flags
            item.state = .ready
            if !flags.isEmpty {
                logger.notice("HDR/DV markers on '\(item.displayName)': \(String(describing: flags))")
            }
            logger.debug("Ready: '\(item.displayName)', duration=\(item.duration ?? 0, format: .fixed(precision: 1))s")
        } catch is CancellationError {
            return
        } catch {
            logger.error("Failed to load '\(item.displayName)': \(error.localizedDescription)")
            item.state = .failed(error.localizedDescription)
        }
    }
}
