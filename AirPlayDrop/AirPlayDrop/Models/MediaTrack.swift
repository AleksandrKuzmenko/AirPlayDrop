import Foundation

enum MediaTrackKind: String, Codable, Sendable { case video, audio, subtitle }

struct MediaTrack: Identifiable, Codable, Equatable, Sendable {
    let id: Int
    let kind: MediaTrackKind
    let codec: String
    let language: String?
    let title: String?
    let channels: Int?
    let isDefault: Bool
    let isTextSubtitle: Bool

    var displayName: String {
        let label = title ?? language?.uppercased() ?? "Track \(id)"
        let details = [codec.uppercased(), channels.map { "\($0) ch" }]
            .compactMap { $0 }
            .joined(separator: " · ")
        return details.isEmpty ? label : "\(label) — \(details)"
    }
}

struct MediaInfo: Codable, Equatable, Sendable {
    let formatName: String?
    let duration: Double?
    let videoCodec: String?
    let videoProfile: String?
    let pixelFormat: String?
    let colorTransfer: String?
    let isDolbyVision: Bool
    let tracks: [MediaTrack]

    var audioTracks: [MediaTrack] { tracks.filter { $0.kind == .audio } }
    var subtitleTracks: [MediaTrack] { tracks.filter { $0.kind == .subtitle } }
    var hasAudio: Bool { !audioTracks.isEmpty }
    var isHDR: Bool {
        isDolbyVision || colorTransfer == "smpte2084" || colorTransfer == "arib-std-b67"
    }
}

enum SubtitlePolicy: String, Codable, CaseIterable, Sendable {
    case omit
    case includeSelected

    var label: String { self == .omit ? "No subtitles" : "Include selected subtitle" }
}

struct TrackSelection: Codable, Equatable, Sendable {
    var audioID: Int?
    var subtitleID: Int?
    var subtitlePolicy: SubtitlePolicy = .omit
}

enum PlaybackIntent: String, Codable, CaseIterable, Sendable {
    case local
    case airPlay

    var label: String { self == .local ? "This Mac" : "Apple TV / AirPlay" }
}

enum ConversionStrategy: String, Codable, Sendable {
    case directPlay, remux, audioTranscode, hdrRemux, hardwareEncode, softwareEncode
}

struct ConversionStep: Equatable, Sendable {
    let strategy: ConversionStrategy
    let reason: String
    let videoArguments: [String]
    let audioArguments: [String]
    let requiresHVC1: Bool
}

struct ConversionPlan: Equatable, Sendable {
    let intent: PlaybackIntent
    let steps: [ConversionStep]
    let reason: String
}

enum TranscodePlanner {
    static func plan(info: MediaInfo, intent: PlaybackIntent, selectedAudioID: Int? = nil) -> ConversionPlan {
        let video = info.videoCodec?.lowercased()
        let audio = info.audioTracks.first(where: { $0.id == selectedAudioID })?.codec.lowercased()
            ?? info.audioTracks.first?.codec.lowercased()

        if intent == .local,
           ["mov,mp4,m4a,3gp,3g2,mj2", "mp4", "mov"].contains(info.formatName),
           ["h264", "hevc"].contains(video),
           [nil, "aac", "ac3", "eac3"].contains(audio) {
            return ConversionPlan(intent: intent, steps: [], reason: "The source is already compatible with local playback.")
        }

        if intent == .airPlay, video == "hevc", info.isHDR {
            return ConversionPlan(intent: intent, steps: [
                ConversionStep(strategy: .hdrRemux,
                    reason: "Preserve the HEVC HDR base layer, remove Dolby Vision RPU data, and create an hvc1 MP4.",
                    videoArguments: ["-c:v", "copy", "-bsf:v", "filter_units=remove_types=62", "-tag:v", "hvc1"],
                    audioArguments: ["-c:a", "aac", "-ac:a", "2", "-b:a", "192k"], requiresHVC1: true),
                ConversionStep(strategy: .hardwareEncode,
                    reason: "Re-encode HDR as HEVC Main 10 when the lossless HDR remux is rejected.",
                    videoArguments: ["-c:v", "hevc_videotoolbox", "-profile:v", "main10", "-pix_fmt", "p010le", "-b:v", "12000k", "-tag:v", "hvc1"],
                    audioArguments: ["-c:a", "aac", "-ac:a", "2", "-b:a", "192k"], requiresHVC1: true)
            ], reason: info.isDolbyVision ? "Dolby Vision needs an Apple TV compatible HDR10 fallback." : "HDR HEVC needs an AirPlay-safe MP4 sample entry.")
        }

        var steps: [ConversionStep] = []
        if ["h264", "hevc"].contains(video) {
            if audio == "aac" || audio == nil {
                steps.append(ConversionStep(strategy: .remux, reason: "Repackage compatible streams without quality loss.",
                    videoArguments: ["-c:v", "copy"], audioArguments: ["-c:a", "copy"], requiresHVC1: video == "hevc"))
            }
            steps.append(ConversionStep(strategy: .audioTranscode, reason: "Keep compatible video and convert the selected audio track to AAC.",
                videoArguments: ["-c:v", "copy"] + (video == "hevc" ? ["-tag:v", "hvc1"] : []),
                audioArguments: ["-c:a", "aac", "-ac:a", "2", "-b:a", "192k"], requiresHVC1: video == "hevc"))
        }
        steps.append(ConversionStep(strategy: .hardwareEncode, reason: "Use Apple hardware encoding for broad playback compatibility.",
            videoArguments: ["-c:v", "h264_videotoolbox", "-b:v", "5000k"],
            audioArguments: ["-c:a", "aac", "-ac:a", "2", "-b:a", "192k"], requiresHVC1: false))
        steps.append(ConversionStep(strategy: .softwareEncode, reason: "Use the software encoder if hardware encoding is unavailable.",
            videoArguments: ["-c:v", "libx264", "-preset", "fast", "-crf", "20"],
            audioArguments: ["-c:a", "aac", "-ac:a", "2", "-b:a", "192k"], requiresHVC1: false))
        return ConversionPlan(intent: intent, steps: steps, reason: "Prepare a compatible MP4 using the least destructive available strategy.")
    }
}
