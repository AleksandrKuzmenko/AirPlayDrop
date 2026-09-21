import AVFoundation
import Foundation

struct MediaArtifactValidation: Equatable, Sendable {
    let isValid: Bool
    let hasVideo: Bool
    let hasAudio: Bool
    let duration: Double?
    let reason: String?
}

enum MediaArtifactValidator {
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
        let temporary = directory.appendingPathComponent("." + destination.lastPathComponent + ".\(UUID().uuidString).partial")
        return OutputReservation(destination: destination, temporary: temporary)
    }
}
