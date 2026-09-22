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
    let sourceHadAudio: Bool
    let selectedAudioID: Int?
    let expectedDuration: Double?
    let requiresHVC1: Bool
    let selectedSubtitle: SubtitleSelection
    let syncAdjustment: SyncAdjustment
    let audioProcessingMode: AudioProcessingMode
    let audioProcessingPresetVersion: Int
    let playbackIntent: PlaybackIntent
}

enum MediaArtifactError: LocalizedError {
    case missingFingerprint
    case missingOutputSize

    var errorDescription: String? {
        switch self {
        case .missingFingerprint: return "The source fingerprint could not be read."
        case .missingOutputSize: return "The prepared output size could not be read."
        }
    }
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

    static func writeManifest(source: URL, artifact: URL, sourceHadAudio: Bool,
                              selectedAudioID: Int?, expectedDuration: Double?, requiresHVC1: Bool,
                              selectedSubtitle: SubtitleSelection = .none,
                              syncAdjustment: SyncAdjustment = .zero,
                              audioProcessingMode: AudioProcessingMode = .standard,
                              audioProcessingPresetVersion: Int = AudioProcessingPreset.version,
                              playbackIntent: PlaybackIntent = .local) throws {
        guard let fingerprint = sourceFingerprint(source) else { throw MediaArtifactError.missingFingerprint }
        guard let outputValues = try? artifact.resourceValues(forKeys: [.fileSizeKey]),
              let outputSize = outputValues.fileSize else { throw MediaArtifactError.missingOutputSize }
        let manifest = MediaArtifactManifest(schemaVersion: 6, sourcePath: source.standardizedFileURL.path,
            sourceSize: fingerprint.0, sourceModification: fingerprint.1, outputSize: Int64(outputSize),
            sourceHadAudio: sourceHadAudio, selectedAudioID: selectedAudioID,
            expectedDuration: expectedDuration, requiresHVC1: requiresHVC1,
            selectedSubtitle: selectedSubtitle, syncAdjustment: syncAdjustment,
            audioProcessingMode: audioProcessingMode,
            audioProcessingPresetVersion: audioProcessingPresetVersion,
            playbackIntent: playbackIntent)
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: manifestURL(for: artifact), options: .atomic)
    }

    static func validateCached(_ artifact: URL, source: URL,
                               expectedSelectedAudioID: Int? = nil,
                               expectedSelection: TrackSelection? = nil,
                               expectedSyncAdjustment: SyncAdjustment = .zero,
                               expectedAudioProcessingMode: AudioProcessingMode = .standard,
                               expectedIntent: PlaybackIntent = .local) async -> MediaArtifactValidation {
        guard let data = try? Data(contentsOf: manifestURL(for: artifact)),
              let manifest = try? JSONDecoder().decode(MediaArtifactManifest.self, from: data),
              manifest.schemaVersion == 6,
              manifest.sourcePath == source.standardizedFileURL.path,
              let fingerprint = sourceFingerprint(source),
              manifest.sourceSize == fingerprint.0,
              manifest.sourceModification == fingerprint.1,
              manifest.selectedAudioID == (expectedSelection?.audioID ?? expectedSelectedAudioID),
              manifest.selectedSubtitle == (expectedSelection?.subtitle ?? .none),
              manifest.syncAdjustment == expectedSyncAdjustment,
              manifest.audioProcessingMode == expectedAudioProcessingMode,
              manifest.audioProcessingPresetVersion == AudioProcessingPreset.version,
              manifest.playbackIntent == expectedIntent,
              (manifest.selectedSubtitle.externalDescriptor == nil || manifest.selectedSubtitle.externalDescriptor?.isCurrent == true),
              let outputValues = try? artifact.resourceValues(forKeys: [.fileSizeKey]),
              Int64(outputValues.fileSize ?? -1) == manifest.outputSize else {
            return MediaArtifactValidation(isValid: false, hasVideo: false, hasAudio: false, duration: nil, reason: "No current artifact manifest")
        }
        return await validate(artifact, sourceHadAudio: manifest.sourceHadAudio,
            expectedDuration: manifest.expectedDuration, requiresHVC1: manifest.requiresHVC1)
    }

    static func validate(_ url: URL, sourceHadAudio: Bool = true,
                         expectedDuration: Double? = nil, requiresHVC1: Bool = false) async -> MediaArtifactValidation {
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
            let durationMatches: Bool
            if let expectedDuration, expectedDuration > 0, let seconds {
                durationMatches = abs(seconds - expectedDuration) <= max(2, expectedDuration * 0.02)
            } else {
                durationMatches = true
            }
            let hasRequiredCodec: Bool
            if requiresHVC1, let first = video.first,
               let descriptions = try? await first.load(.formatDescriptions) {
                hasRequiredCodec = descriptions.contains {
                    CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_HEVC
                }
            } else {
                hasRequiredCodec = !requiresHVC1
            }
            let valid = playable && hasVideo && (!sourceHadAudio || hasAudio) && durationMatches && hasRequiredCodec
            return MediaArtifactValidation(isValid: valid, hasVideo: hasVideo, hasAudio: hasAudio,
                duration: seconds, reason: valid ? nil : validationReason(playable: playable, hasVideo: hasVideo,
                    sourceHadAudio: sourceHadAudio, hasAudio: hasAudio, durationMatches: durationMatches,
                    codecMatches: hasRequiredCodec))
        } catch {
            return MediaArtifactValidation(isValid: false, hasVideo: false, hasAudio: false, duration: nil, reason: error.localizedDescription)
        }
    }

    private static func validationReason(playable: Bool, hasVideo: Bool, sourceHadAudio: Bool,
                                         hasAudio: Bool, durationMatches: Bool, codecMatches: Bool) -> String {
        if !playable || !hasVideo { return "Output is not a playable video." }
        if sourceHadAudio && !hasAudio { return "The selected source audio track is missing from the output." }
        if !durationMatches { return "Output duration differs from the source." }
        if !codecMatches { return "Output does not use the required hvc1 HEVC sample entry." }
        return "Output validation failed."
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

    static func existingArtifacts(for input: URL, fileManager: FileManager = .default) -> [URL] {
        let directory = input.deletingLastPathComponent()
        let stem = input.deletingPathExtension().lastPathComponent + "_airplay"
        let urls = (try? fileManager.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        return urls.filter {
            $0.pathExtension.lowercased() == "mp4" &&
            ($0.deletingPathExtension().lastPathComponent == stem ||
             $0.deletingPathExtension().lastPathComponent.hasPrefix(stem + "_"))
        }.sorted { lhs, rhs in
            let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left > right
        }
    }
}
