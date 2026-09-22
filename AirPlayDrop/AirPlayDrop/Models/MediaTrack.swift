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
    let isForced: Bool

    init(id: Int, kind: MediaTrackKind, codec: String, language: String?, title: String?,
         channels: Int?, isDefault: Bool, isTextSubtitle: Bool, isForced: Bool = false) {
        self.id = id
        self.kind = kind
        self.codec = codec
        self.language = language
        self.title = title
        self.channels = channels
        self.isDefault = isDefault
        self.isTextSubtitle = isTextSubtitle
        self.isForced = isForced
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, codec, language, title, channels, isDefault, isTextSubtitle, isForced
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try values.decode(Int.self, forKey: .id),
                  kind: try values.decode(MediaTrackKind.self, forKey: .kind),
                  codec: try values.decode(String.self, forKey: .codec),
                  language: try values.decodeIfPresent(String.self, forKey: .language),
                  title: try values.decodeIfPresent(String.self, forKey: .title),
                  channels: try values.decodeIfPresent(Int.self, forKey: .channels),
                  isDefault: try values.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false,
                  isTextSubtitle: try values.decodeIfPresent(Bool.self, forKey: .isTextSubtitle) ?? false,
                  isForced: try values.decodeIfPresent(Bool.self, forKey: .isForced) ?? false)
    }

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

struct ExternalSubtitleDescriptor: Codable, Equatable, Sendable {
    let url: URL
    let language: String?
    let displayName: String
    let fileSize: Int64
    let modificationDate: Date?

    init(url: URL, language: String? = nil, displayName: String? = nil,
         fileSize: Int64, modificationDate: Date?) {
        self.url = url.standardizedFileURL
        self.language = language.map { PlaybackPreferences.normalizedCodes([$0]).first }.flatMap { $0 }
        self.displayName = displayName ?? url.lastPathComponent
        self.fileSize = fileSize
        self.modificationDate = modificationDate
    }

    var standardizedURL: URL { url.standardizedFileURL }

    static func make(url: URL, language: String? = nil) -> ExternalSubtitleDescriptor? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize else { return nil }
        return ExternalSubtitleDescriptor(url: url, language: language, fileSize: Int64(size),
                                          modificationDate: values.contentModificationDate)
    }

    var isCurrent: Bool {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize else { return false }
        return Int64(size) == fileSize && values.contentModificationDate == modificationDate
    }
}

enum SubtitleSelection: Codable, Equatable, Sendable {
    case none
    case embedded(streamID: Int)
    case external(ExternalSubtitleDescriptor)

    static func embedded(id: Int) -> SubtitleSelection { .embedded(streamID: id) }
    static func external(descriptor: ExternalSubtitleDescriptor) -> SubtitleSelection { .external(descriptor) }

    var embeddedID: Int? {
        guard case .embedded(let streamID) = self else { return nil }
        return streamID
    }

    var externalDescriptor: ExternalSubtitleDescriptor? {
        guard case .external(let descriptor) = self else { return nil }
        return descriptor
    }

    var isNone: Bool {
        if case .none = self { return true }
        return false
    }
}

struct TrackSelection: Codable, Equatable, Sendable {
    var audioID: Int?
    var subtitle: SubtitleSelection
    var subtitlePolicy: SubtitlePolicy = .omit

    init(audioID: Int? = nil, subtitleID: Int? = nil, subtitlePolicy: SubtitlePolicy = .omit,
         subtitle: SubtitleSelection? = nil) {
        self.audioID = audioID
        self.subtitle = subtitle ?? (subtitleID.map { .embedded(streamID: $0) } ?? .none)
        self.subtitlePolicy = subtitlePolicy
    }

    init(audioID: Int? = nil, subtitle: SubtitleSelection, subtitlePolicy: SubtitlePolicy = .omit) {
        self.audioID = audioID
        self.subtitle = subtitle
        self.subtitlePolicy = subtitlePolicy
    }

    var subtitleID: Int? {
        get { subtitle.embeddedID }
        set {
            subtitle = newValue.map { .embedded(streamID: $0) } ?? .none
        }
    }

    var hasSelectedSubtitle: Bool {
        subtitlePolicy == .includeSelected && !subtitle.isNone
    }
}

enum PlaybackIntent: String, Codable, CaseIterable, Sendable {
    case local
    case airPlay

    var label: String { self == .local ? "This Mac" : "Apple TV / AirPlay" }
}

enum ConversionStrategy: String, Codable, Sendable {
    case directPlay, remux, audioTranscode, hdrRemux, hardwareEncode, softwareEncode
}

enum AudioProcessingMode: String, Codable, CaseIterable, Sendable {
    case standard
    case lateNight

    var label: String {
        switch self {
        case .standard: return "Standard"
        case .lateNight: return "Late Night (Dialogue Focus)"
        }
    }
}

enum AudioProcessingPreset {
    static let version = 1
    static let lateNightFilter = "acompressor=threshold=-30dB:ratio=8:attack=5:release=250:makeup=8dB,alimiter=limit=-0.5dB"
}

enum SyncAdjustmentLimits {
    static let limitMilliseconds = 10_000
}

struct SyncAdjustment: Codable, Equatable, Sendable {
    static let zero = SyncAdjustment()
    var audioMilliseconds: Int {
        didSet { audioMilliseconds = Self.clamp(audioMilliseconds) }
    }
    var subtitleMilliseconds: Int {
        didSet { subtitleMilliseconds = Self.clamp(subtitleMilliseconds) }
    }

    init(audioMilliseconds: Int = 0, subtitleMilliseconds: Int = 0) {
        self.audioMilliseconds = Self.clamp(audioMilliseconds)
        self.subtitleMilliseconds = Self.clamp(subtitleMilliseconds)
    }

    private static func clamp(_ value: Int) -> Int {
        min(max(value, -SyncAdjustmentLimits.limitMilliseconds), SyncAdjustmentLimits.limitMilliseconds)
    }

    var isZero: Bool { audioMilliseconds == 0 && subtitleMilliseconds == 0 }
}

struct ConversionStep: Equatable, Sendable {
    let strategy: ConversionStrategy
    let reason: String
    let videoArguments: [String]
    let audioArguments: [String]
    let requiresHVC1: Bool
    let audioProcessingMode: AudioProcessingMode

    init(strategy: ConversionStrategy, reason: String, videoArguments: [String], audioArguments: [String],
         requiresHVC1: Bool, audioProcessingMode: AudioProcessingMode = .standard) {
        self.strategy = strategy
        self.reason = reason
        self.videoArguments = videoArguments
        self.audioArguments = audioArguments
        self.requiresHVC1 = requiresHVC1
        self.audioProcessingMode = audioProcessingMode
    }
}

struct ConversionPlan: Equatable, Sendable {
    let intent: PlaybackIntent
    let steps: [ConversionStep]
    let reason: String
}

enum TranscodePlanner {
    static func plan(info: MediaInfo, intent: PlaybackIntent, selectedAudioID: Int? = nil,
                     audioProcessingMode: AudioProcessingMode = .standard,
                     syncAdjustment: SyncAdjustment = .zero,
                     requiresSubtitleMuxing: Bool = false) -> ConversionPlan {
        let video = info.videoCodec?.lowercased()
        let audio = info.audioTracks.first(where: { $0.id == selectedAudioID })?.codec.lowercased()
            ?? info.audioTracks.first?.codec.lowercased()

        if audioProcessingMode == .standard, syncAdjustment.isZero, !requiresSubtitleMuxing, intent == .local,
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
                    audioArguments: ["-c:a", "aac", "-ac:a", "2", "-b:a", "192k"], requiresHVC1: true,
                    audioProcessingMode: audioProcessingMode),
                ConversionStep(strategy: .hardwareEncode,
                    reason: "Re-encode HDR as HEVC Main 10 when the lossless HDR remux is rejected.",
                    videoArguments: ["-c:v", "hevc_videotoolbox", "-profile:v", "main10", "-pix_fmt", "p010le", "-b:v", "12000k", "-tag:v", "hvc1"],
                    audioArguments: ["-c:a", "aac", "-ac:a", "2", "-b:a", "192k"], requiresHVC1: true,
                    audioProcessingMode: audioProcessingMode)
            ], reason: info.isDolbyVision ? "Dolby Vision needs an Apple TV compatible HDR10 fallback." : "HDR HEVC needs an AirPlay-safe MP4 sample entry.")
        }

        var steps: [ConversionStep] = []
        if ["h264", "hevc"].contains(video) {
            if audioProcessingMode == .standard && syncAdjustment.audioMilliseconds == 0 && (audio == "aac" || audio == nil) {
                steps.append(ConversionStep(strategy: .remux, reason: "Repackage compatible streams without quality loss.",
                    videoArguments: ["-c:v", "copy"] + (video == "hevc" ? ["-tag:v", "hvc1"] : []),
                    audioArguments: ["-c:a", "copy"], requiresHVC1: video == "hevc",
                    audioProcessingMode: audioProcessingMode))
            }
            steps.append(ConversionStep(strategy: .audioTranscode, reason: "Keep compatible video and convert the selected audio track to AAC.",
                videoArguments: ["-c:v", "copy"] + (video == "hevc" ? ["-tag:v", "hvc1"] : []),
                audioArguments: ["-c:a", "aac", "-ac:a", "2", "-b:a", "192k"], requiresHVC1: video == "hevc",
                audioProcessingMode: audioProcessingMode))
        }
        if audioProcessingMode == .lateNight && steps.isEmpty {
            steps.append(ConversionStep(strategy: .audioTranscode,
                reason: "Re-encode audio with the optional late-night dialogue-focused preset.",
                videoArguments: ["-c:v", "copy"],
                audioArguments: ["-c:a", "aac", "-ac:a", "2", "-b:a", "192k"],
                requiresHVC1: video == "hevc", audioProcessingMode: .lateNight))
        }
        steps.append(ConversionStep(strategy: .hardwareEncode, reason: "Use Apple hardware encoding for broad playback compatibility.",
            videoArguments: ["-c:v", "h264_videotoolbox", "-b:v", "5000k"],
            audioArguments: ["-c:a", "aac", "-ac:a", "2", "-b:a", "192k"], requiresHVC1: false,
            audioProcessingMode: audioProcessingMode))
        steps.append(ConversionStep(strategy: .softwareEncode, reason: "Use the software encoder if hardware encoding is unavailable.",
            videoArguments: ["-c:v", "libx264", "-preset", "fast", "-crf", "20"],
            audioArguments: ["-c:a", "aac", "-ac:a", "2", "-b:a", "192k"], requiresHVC1: false,
            audioProcessingMode: audioProcessingMode))
        return ConversionPlan(intent: intent, steps: steps, reason: "Prepare a compatible MP4 using the least destructive available strategy.")
    }
}
