import AVFoundation
import CoreGraphics
import Foundation

protocol ThumbnailImageGenerating: AnyObject {
    func image(at time: CMTime, maximumSize: CGSize) throws -> CGImage
}

private final class AVAssetThumbnailGenerator: ThumbnailImageGenerating, @unchecked Sendable {
    private let generator: AVAssetImageGenerator

    init(url: URL) {
        let asset = AVURLAsset(url: url)
        generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 270)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.75, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.75, preferredTimescale: 600)
    }

    func image(at time: CMTime, maximumSize: CGSize) throws -> CGImage {
        generator.maximumSize = maximumSize
        return try generator.copyCGImage(at: time, actualTime: nil)
    }
}

struct ThumbnailCacheKey: Hashable, Sendable {
    let url: URL
    let fileSize: Int64
    let modificationDate: Date?
    let bucket: Int
}

actor ThumbnailProvider {
    static let bucketDuration: Double = 2
    static let maximumEntries = 30

    private let generatorFactory: @Sendable (URL) -> ThumbnailImageGenerating
    private var cache: [ThumbnailCacheKey: CGImage] = [:]
    private var lru: [ThumbnailCacheKey] = []
    private var disabledFingerprints: [URL: (Int64, Date?)] = [:]

    init(generatorFactory: @escaping @Sendable (URL) -> ThumbnailImageGenerating = { AVAssetThumbnailGenerator(url: $0) }) {
        self.generatorFactory = generatorFactory
    }

    static func quantizedBucket(_ seconds: Double) -> Int? {
        guard seconds.isFinite, seconds >= 0 else { return nil }
        return Int(floor(seconds / bucketDuration))
    }

    func image(for url: URL, at seconds: Double, duration: Double? = nil) async -> CGImage? {
        guard let bucket = Self.quantizedBucket(seconds),
              seconds.isFinite,
              duration.map({ $0.isFinite && $0 >= 0 }) ?? true else { return nil }
        let standardized = url.standardizedFileURL
        guard let values = try? standardized.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize else { return nil }
        if let disabled = disabledFingerprints[standardized],
           disabled.0 != Int64(size) || disabled.1 != values.contentModificationDate {
            disabledFingerprints.removeValue(forKey: standardized)
        }
        guard disabledFingerprints[standardized] == nil else { return nil }
        if let duration, duration > 0, seconds > duration { return nil }
        let key = ThumbnailCacheKey(url: standardized, fileSize: Int64(size),
                                    modificationDate: values.contentModificationDate, bucket: bucket)
        if let cached = cache[key] {
            touch(key)
            return cached
        }
        let generator = generatorFactory(standardized)
        do {
            let image = try generator.image(at: CMTime(seconds: Double(bucket) * Self.bucketDuration,
                                                       preferredTimescale: 600),
                                            maximumSize: CGSize(width: 480, height: 270))
            cache[key] = image
            touch(key)
            while lru.count > Self.maximumEntries {
                let old = lru.removeFirst()
                cache.removeValue(forKey: old)
            }
            return image
        } catch {
            if error is CancellationError { return nil }
            // A failing source is disabled until its URL fingerprint changes.
            disabledFingerprints[standardized] = (Int64(size), values.contentModificationDate)
            return nil
        }
    }

    func clear(for url: URL? = nil) {
        if let url {
            let standardized = url.standardizedFileURL
            cache = cache.filter { $0.key.url != standardized }
            lru.removeAll { $0.url == standardized }
            disabledFingerprints.removeValue(forKey: standardized)
        } else {
            cache.removeAll(); lru.removeAll(); disabledFingerprints.removeAll()
        }
    }

    func cachedEntryCount() -> Int { cache.count }

    private func touch(_ key: ThumbnailCacheKey) {
        lru.removeAll { $0 == key }
        lru.append(key)
    }
}
