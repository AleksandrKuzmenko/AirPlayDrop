import AVFoundation
import Foundation

struct MediaArtifactValidation: Equatable, Sendable {
    let isValid: Bool
    let hasVideo: Bool
    let hasAudio: Bool
    let duration: Double?
    let reason: String?
}

struct MediaArtifactManifest: Codable, Sendable {
    let schemaVersion: Int
    let sourcePath: String
    let sourceSize: Int64
    let sourceModification: Date?
    let outputSize: Int64
    let hasVideo: Bool
    let hasAudio: Bool
    let duration: Double?
}

enum MediaArtifactValidator {
    static func manifestURL(for artifact: URL) -> URL {
        artifact.appendingPathExtension("airplay.json")
    }

    static func sourceFingerprint(_ source: URL) -> (Int64, Date?)? {
        guard let values = try? source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize else { return nil }
        return (Int64(size), values.contentModificationDate)
    }

    static func writeManifest(source: URL, artifact: URL, validation: MediaArtifactValidation) throws {
        guard let fingerprint = sourceFingerprint(source),
              let outputValues = try? artifact.resourceValues(forKeys: [.fileSizeKey]),
              let outputSize = outputValues.fileSize else { return }
        let manifest = MediaArtifactManifest(schemaVersion: 1, sourcePath: source.standardizedFileURL.path,
            sourceSize: fingerprint.0, sourceModification: fingerprint.1, outputSize: Int64(outputSize),
            hasVideo: validation.hasVideo, hasAudio: validation.hasAudio, duration: validation.duration)
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: manifestURL(for: artifact), options: .atomic)
    }

    static func validateCached(_ artifact: URL, source: URL) async -> MediaArtifactValidation {
        guard let data = try? Data(contentsOf: manifestURL(for: artifact)),
              let manifest = try? JSONDecoder().decode(MediaArtifactManifest.self, from: data),
              manifest.schemaVersion == 1,
              manifest.sourcePath == source.standardizedFileURL.path,
              let fingerprint = sourceFingerprint(source),
              manifest.sourceSize == fingerprint.0,
              manifest.sourceModification == fingerprint.1 else {
            return MediaArtifactValidation(isValid: false, hasVideo: false, hasAudio: false, duration: nil, reason: "No current artifact manifest")
        }
        return await validate(artifact, sourceHadAudio: manifest.hasAudio)
    }

    static func validate(_ url: URL, sourceHadAudio: Bool = true) async -> MediaArtifactValidation {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              (values.fileSize ?? 0) > 0 else {
            return MediaArtifactValidation(isValid: false, hasVideo: false, hasAudio: false, duration: nil, reason: "Output is empty or missing")
        }
        let asset = AVURLAsset(url: url)
        do {
            let playable = try await asset.load(.isPlayable)
            let video = try await asset.loadTracks(withMediaType: .video)
            let audio = try await asset.loadTracks(withMediaType: .audio)
            let duration = try? await asset.load(.duration)
            let seconds = duration.flatMap { $0.isNumeric ? $0.seconds : nil }
            let hasVideo = !video.isEmpty
            let hasAudio = !audio.isEmpty
            let valid = playable && hasVideo && (!sourceHadAudio || hasAudio)
            return MediaArtifactValidation(isValid: valid, hasVideo: hasVideo, hasAudio: hasAudio,
                duration: seconds, reason: valid ? nil : "Output is not a playable video with the expected audio track")
        } catch {
            return MediaArtifactValidation(isValid: false, hasVideo: false, hasAudio: false, duration: nil, reason: error.localizedDescription)
        }
    }
}

struct OutputReservation: Sendable {
    let destination: URL
    let temporary: URL

    static func reserve(for input: URL, fileManager: FileManager = .default) throws -> OutputReservation {
        let directory = input.deletingLastPathComponent()
        let stem = input.deletingPathExtension().lastPathComponent + "_airplay"
        var index = 0
        var destination: URL
        repeat {
            let suffix = index == 0 ? "" : "_\(index)"
            destination = directory.appendingPathComponent(stem + suffix + ".mp4")
            index += 1
        } while fileManager.fileExists(atPath: destination.path)
        // Keep the .mp4 suffix: FFmpeg selects the muxer from the output extension.
        let temporary = directory.appendingPathComponent("." + destination.lastPathComponent + ".\(UUID().uuidString).mp4")
        return OutputReservation(destination: destination, temporary: temporary)
    }
}
