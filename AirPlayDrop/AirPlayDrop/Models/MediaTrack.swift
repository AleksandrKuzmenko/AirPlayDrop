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
    /// Dolby Vision profile from the DOVI configuration record (for example 5, 7, or 8).
    var dolbyVisionProfile: Int? = nil
    /// Base-layer signal compatibility ID; 0 means no HDR10/SDR-compatible base layer.
    var dolbyVisionCompatibilityID: Int? = nil
    /// Display-matrix rotation in degrees, when present.
    var rotation: Double? = nil
    /// FFmpeg colour primaries name, such as `bt2020`.
    var colorPrimaries: String? = nil
    /// FFmpeg colour matrix name, such as `bt2020nc`.
    var colorSpace: String? = nil
    var width: Int? = nil
    var height: Int? = nil
    /// FFprobe `avg_frame_rate`, a rational such as `24000/1001`; `0/0` when unknown.
    var averageFrameRate: String? = nil

    /// Frames per second, or nil when FFprobe could not determine the rate.
    var frameRate: Double? {
        guard let (numerator, denominator) = AppleTVVideoCompatibility.rational(averageFrameRate),
              numerator > 0 else { return nil }
        return Double(numerator) / Double(denominator)
    }

    /// The PQ or HLG transfer function when the video signals HDR10 or HLG.
    var hdrTransfer: String? {
        ["smpte2084", "arib-std-b67"].contains(colorTransfer) ? colorTransfer : nil
    }

    var audioTracks: [MediaTrack] { tracks.filter { $0.kind == .audio } }
    var subtitleTracks: [MediaTrack] { tracks.filter { $0.kind == .subtitle } }
    var hasAudio: Bool { !audioTracks.isEmpty }
    var isHDR: Bool {
        isDolbyVision || colorTransfer == "smpte2084" || colorTransfer == "arib-std-b67"
    }
    var formatFlags: Set<VideoFormatFlag> {
        var flags: Set<VideoFormatFlag> = []
        if isDolbyVision { flags.insert(.dolbyVision) }
        if colorTransfer == "smpte2084" { flags.insert(.hdr10) }
        if colorTransfer == "arib-std-b67" { flags.insert(.hlg) }
        return flags
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
    case directPlay, remux, audioTranscode, hdrRemux, hardwareEncode
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
    /// Bumped to 2 when surround audio started being preserved, so stereo
    /// copies prepared earlier are re-prepared.
    static let version = 2
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
    /// FFmpeg transfer name (`smpte2084` or `arib-std-b67`) the output must
    /// still signal, so an HDR source never silently becomes an SDR-tagged file.
    let requiredTransfer: String?

    init(strategy: ConversionStrategy, reason: String, videoArguments: [String], audioArguments: [String],
         requiresHVC1: Bool, audioProcessingMode: AudioProcessingMode = .standard,
         requiredTransfer: String? = nil) {
        self.strategy = strategy
        self.reason = reason
        self.videoArguments = videoArguments
        self.audioArguments = audioArguments
        self.requiresHVC1 = requiresHVC1
        self.audioProcessingMode = audioProcessingMode
        self.requiredTransfer = requiredTransfer
    }
}

/// Encoder used when surround audio has to be re-encoded.
enum SurroundAudioEncoder: String, Sendable {
    /// Dolby Digital Plus, which Apple TV can pass to a receiver or soundbar.
    case eac3
    /// Multichannel AAC, for FFmpeg builds without the E-AC3 encoder.
    case aac
}

enum AudioArguments {
    /// Codecs Apple TV accepts in MP4. Copying them keeps the original mix,
    /// including any Dolby Atmos carried in E-AC3.
    static let copyableCodecs: Set<String> = ["aac", "ac3", "eac3"]
    static let stereo = ["-c:a", "aac", "-ac:a", "2", "-b:a", "192k"]

    static func canCopy(_ track: MediaTrack?, mode: AudioProcessingMode, syncAdjustment: SyncAdjustment) -> Bool {
        guard mode == .standard, syncAdjustment.audioMilliseconds == 0 else { return false }
        guard let track else { return true }
        return copyableCodecs.contains(track.codec.lowercased())
    }

    /// Re-encode the track, keeping up to 5.1 channels. Late Night output stays
    /// stereo because the preset is meant for speakers at low volume.
    static func encode(_ track: MediaTrack?, mode: AudioProcessingMode,
                       surroundEncoder: SurroundAudioEncoder) -> [String] {
        let channels = track?.channels ?? 2
        guard mode == .standard, channels > 2 else { return stereo }
        let output = min(channels, 6)
        switch surroundEncoder {
        case .eac3: return ["-c:a", "eac3", "-ac:a", "\(output)", "-b:a", output >= 6 ? "640k" : "448k"]
        case .aac: return ["-c:a", "aac", "-ac:a", "\(output)", "-b:a", output >= 6 ? "384k" : "320k"]
        }
    }

    static func preferred(_ track: MediaTrack?, mode: AudioProcessingMode, syncAdjustment: SyncAdjustment,
                          surroundEncoder: SurroundAudioEncoder) -> [String] {
        canCopy(track, mode: mode, syncAdjustment: syncAdjustment)
            ? ["-c:a", "copy"]
            : encode(track, mode: mode, surroundEncoder: surroundEncoder)
    }
}

enum HDRVideoArguments {
    /// HEVC Main 10 VideoToolbox encode that keeps HDR10/HLG signalling.
    /// Apple TV only switches to HDR when the output carries colour tags.
    /// FFmpeg encoders take colour properties from decoded frames and ignore
    /// `-color_trc`-style output options, so the tags are set on the frames
    /// with `setparams`. Missing source primaries or matrix default to
    /// BT.2020, which HDR10 and HLG both specify.
    static func hevcMain10(for info: MediaInfo, intent: PlaybackIntent = .local) -> [String] {
        let limits = intent == .airPlay ? AppleTVVideoCompatibility.conformingArguments(for: info)
                                        : (filters: [], output: [])
        let filters = limits.filters + [colorFilter(for: info)].compactMap { $0 }
        return (filters.isEmpty ? [] : ["-vf", filters.joined(separator: ",")]) + limits.output
            + ["-c:v", "hevc_videotoolbox", "-profile:v", "main10", "-pix_fmt", "p010le",
               "-b:v", "12000k", "-tag:v", "hvc1"]
    }

    static func colorFilter(for info: MediaInfo) -> String? {
        guard let transfer = info.hdrTransfer else { return nil }
        return "setparams=color_primaries=\(known(info.colorPrimaries) ?? "bt2020")"
            + ":color_trc=\(transfer)"
            + ":colorspace=\(known(info.colorSpace) ?? "bt2020nc")"
    }

    private static func known(_ value: String?) -> String? {
        guard let value, !["unknown", "unspecified", "reserved"].contains(value) else { return nil }
        return value
    }
}

/// What an Apple TV can decode from a stream-copied AirPlay MP4.
///
/// Apple's HLS authoring specification for Apple devices limits H.264 to
/// High Profile or lower and HEVC to Main 10 Profile or lower, and says
/// frame rates above 60 fps shall not be used. Those profiles mean 8-bit
/// 4:2:0 H.264 and 8- or 10-bit 4:2:0 HEVC, so High 10, 4:2:2, 4:4:4, and
/// HEVC range-extension streams are converted even when the Mac plays them.
/// The Apple TV 4K specifications (apple.com/apple-tv-4k/specs) give the
/// "up to 2160p, 60 fps" ceiling.
///
/// The rules are deliberately conservative where they are strict and lenient
/// where probes are unreliable. AV1 and VP9 are always converted for AirPlay:
/// the Apple TV 4K specifications list them, but not every Apple TV decodes
/// them and AirPlay of them is unverified. Levels are not checked because
/// encoders often misreport them, and a false rejection costs a lossy
/// re-encode. Unknown fields and unrecognised profile names count as compatible
/// for the same reason; the pixel format still catches bit depth and chroma.
enum AppleTVVideoCompatibility {
    /// Bump when the rules change so AirPlay copies prepared under older rules are re-prepared.
    static let rulesVersion = 1
    static let maxLongSide = 4096
    static let maxShortSide = 2160
    static let maxFrameRate = 60.0
    /// Variable-frame-rate phone and screen recordings nominally at 60 fps
    /// often probe slightly above it.
    static let frameRateLimit = maxFrameRate * 1.05

    /// FFprobe profile names above H.264 High and HEVC Main 10.
    static let unsupportedProfiles: [String: Set<String>] = [
        "h264": ["High 10", "High 10 Intra", "High 4:2:2", "High 4:2:2 Intra", "High 4:4:4",
                 "High 4:4:4 Predictive", "High 4:4:4 Intra", "CAVLC 4:4:4", "CAVLC 4:4:4 Intra"],
        "hevc": ["Rext", "SCC"],
    ]
    static let pixelFormats: [String: Set<String>] = [
        "h264": ["yuv420p", "yuvj420p"],
        "hevc": ["yuv420p", "yuvj420p", "yuv420p10le"],
    ]

    enum Issue: Equatable, Sendable {
        case codec(String)
        case profile(String)
        case pixelFormat(String)
        case resolution(width: Int, height: Int)
        case frameRate(Double)

        var description: String {
            switch self {
            case .codec(let codec): return "\(codec.uppercased()) video"
            case .profile(let profile): return "the \(profile) profile"
            case .pixelFormat(let format): return "\(format) pixels"
            case .resolution(let width, let height): return "\(width)×\(height) resolution"
            case .frameRate(let rate): return "\(String(format: "%.4g", rate)) fps"
            }
        }
    }

    static func issues(for info: MediaInfo) -> [Issue] {
        guard let codec = info.videoCodec?.lowercased() else { return [] }
        guard let blockedProfiles = unsupportedProfiles[codec], let allowedFormats = pixelFormats[codec] else {
            return [.codec(codec)]
        }
        var issues: [Issue] = []
        if let profile = info.videoProfile, blockedProfiles.contains(profile) {
            issues.append(.profile(profile))
        }
        if let format = info.pixelFormat, !allowedFormats.contains(format) {
            issues.append(.pixelFormat(format))
        }
        if exceedsResolution(info), let width = info.width, let height = info.height {
            issues.append(.resolution(width: width, height: height))
        }
        if let rate = info.frameRate, rate > frameRateLimit {
            issues.append(.frameRate(rate))
        }
        return issues
    }

    static func isCompatible(_ info: MediaInfo) -> Bool { issues(for: info).isEmpty }

    static func reason(for issues: [Issue]) -> String {
        "Apple TV cannot play " + issues.map(\.description).joined(separator: ", ") + " streamed over AirPlay."
    }

    /// Filters and output options that bring an encode within Apple TV limits.
    static func conformingArguments(for info: MediaInfo) -> (filters: [String], output: [String]) {
        var filters: [String] = []
        if exceedsResolution(info), let width = info.width, let height = info.height {
            let (w, h) = width >= height ? (maxLongSide, maxShortSide) : (maxShortSide, maxLongSide)
            filters.append("scale=w=\(w):h=\(h):force_original_aspect_ratio=decrease:force_divisible_by=2")
        }
        var output: [String] = []
        if let (numerator, denominator) = rational(info.averageFrameRate), let rate = info.frameRate,
           rate > frameRateLimit {
            // Divide by a whole number so 120 becomes 60 and 119.88 becomes 59.94.
            let divisor = Int((rate / frameRateLimit).rounded(.up))
            output = ["-r", "\(numerator)/\(denominator * divisor)"]
        }
        return (filters, output)
    }

    static func rational(_ value: String?) -> (Int, Int)? {
        guard let parts = value?.split(separator: "/"), parts.count == 2,
              let numerator = Int(parts[0]), let denominator = Int(parts[1]), denominator > 0 else { return nil }
        return (numerator, denominator)
    }

    private static func exceedsResolution(_ info: MediaInfo) -> Bool {
        guard let width = info.width, let height = info.height else { return false }
        return max(width, height) > maxLongSide || min(width, height) > maxShortSide
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
                     requiresSubtitleMuxing: Bool = false,
                     surroundEncoder: SurroundAudioEncoder = .eac3) -> ConversionPlan {
        let video = info.videoCodec?.lowercased()
        let appleTVIssues = intent == .airPlay ? AppleTVVideoCompatibility.issues(for: info) : []
        // Local playback copies any H.264/HEVC. AirPlay copies only video the Apple TV decodes.
        let canCopyVideo = ["h264", "hevc"].contains(video) && appleTVIssues.isEmpty
        let conforming = intent == .airPlay ? AppleTVVideoCompatibility.conformingArguments(for: info)
                                            : (filters: [], output: [])
        let h264Filters = conforming.filters + ["format=yuv420p"]
        let h264Encode = ["-vf", h264Filters.joined(separator: ",")] + conforming.output
            + ["-c:v", "h264_videotoolbox", "-b:v", "5000k"]
        let audioTrack = info.audioTracks.first(where: { $0.id == selectedAudioID }) ?? info.audioTracks.first
        let audio = audioTrack?.codec.lowercased()
        let preferredAudio = AudioArguments.preferred(audioTrack, mode: audioProcessingMode,
            syncAdjustment: syncAdjustment, surroundEncoder: surroundEncoder)
        let encodedAudio = AudioArguments.encode(audioTrack, mode: audioProcessingMode,
                                                 surroundEncoder: surroundEncoder)
        // Video-encode steps copy compatible audio first. When that copy is in
        // use, a second step with re-encoded audio follows as the fallback.
        func encodeSteps(strategy: ConversionStrategy, reason: String, videoArguments: [String],
                         requiresHVC1: Bool, requiredTransfer: String?) -> [ConversionStep] {
            var audioVariants = [preferredAudio]
            if preferredAudio != encodedAudio { audioVariants.append(encodedAudio) }
            return audioVariants.map {
                ConversionStep(strategy: strategy, reason: reason, videoArguments: videoArguments,
                    audioArguments: $0, requiresHVC1: requiresHVC1,
                    audioProcessingMode: audioProcessingMode, requiredTransfer: requiredTransfer)
            }
        }

        if audioProcessingMode == .standard, syncAdjustment.isZero, !requiresSubtitleMuxing, intent == .local,
           ["mov,mp4,m4a,3gp,3g2,mj2", "mp4", "mov"].contains(info.formatName),
           ["h264", "hevc"].contains(video),
           [nil, "aac", "ac3", "eac3"].contains(audio) {
            return ConversionPlan(intent: intent, steps: [], reason: "The source is already compatible with local playback.")
        }

        if intent == .airPlay, video == "hevc", info.isHDR {
            let remux = !canCopyVideo ? [] : [
                ConversionStep(strategy: .hdrRemux,
                    reason: "Preserve the HEVC HDR base layer, remove Dolby Vision RPU data, and create an hvc1 MP4.",
                    videoArguments: ["-c:v", "copy", "-bsf:v", "filter_units=remove_types=62", "-tag:v", "hvc1"],
                    audioArguments: preferredAudio, requiresHVC1: true,
                    audioProcessingMode: audioProcessingMode, requiredTransfer: info.hdrTransfer)
            ]
            let reason = !appleTVIssues.isEmpty ? AppleTVVideoCompatibility.reason(for: appleTVIssues)
                : info.isDolbyVision ? "Dolby Vision needs an Apple TV compatible HDR10 fallback."
                : "HDR HEVC needs an AirPlay-safe MP4 sample entry."
            return ConversionPlan(intent: intent, steps: remux + encodeSteps(strategy: .hardwareEncode,
                    reason: "Re-encode HDR as HEVC Main 10 when the lossless HDR remux is rejected.",
                    videoArguments: HDRVideoArguments.hevcMain10(for: info, intent: intent),
                    requiresHVC1: true, requiredTransfer: info.hdrTransfer), reason: reason)
        }

        // AV1, VP9, and other HDR sources that cannot be stream-copied. The
        // generic H.264 encode would produce 8-bit video still tagged PQ/HLG,
        // so HDR is encoded as HEVC Main 10 instead, with no H.264 fallback.
        if let transfer = info.hdrTransfer, !canCopyVideo {
            return ConversionPlan(intent: intent, steps: encodeSteps(strategy: .hardwareEncode,
                    reason: "Encode HDR video as HEVC Main 10, keeping its HDR signalling.",
                    videoArguments: HDRVideoArguments.hevcMain10(for: info, intent: intent),
                    requiresHVC1: true, requiredTransfer: transfer), reason: "HDR \((video ?? "video").uppercased()) needs a 10-bit HEVC copy to keep HDR on Apple TV.")
        }

        var steps: [ConversionStep] = []
        if canCopyVideo {
            if AudioArguments.canCopy(audioTrack, mode: audioProcessingMode, syncAdjustment: syncAdjustment) {
                steps.append(ConversionStep(strategy: .remux, reason: "Repackage compatible streams without quality loss.",
                    videoArguments: ["-c:v", "copy"] + (video == "hevc" ? ["-tag:v", "hvc1"] : []),
                    audioArguments: ["-c:a", "copy"], requiresHVC1: video == "hevc",
                    audioProcessingMode: audioProcessingMode))
            }
            steps.append(ConversionStep(strategy: .audioTranscode,
                reason: "Keep compatible video and convert the selected audio track to an Apple TV compatible format.",
                videoArguments: ["-c:v", "copy"] + (video == "hevc" ? ["-tag:v", "hvc1"] : []),
                audioArguments: encodedAudio, requiresHVC1: video == "hevc",
                audioProcessingMode: audioProcessingMode))
        }
        if audioProcessingMode == .lateNight && steps.isEmpty && intent == .local {
            steps.append(ConversionStep(strategy: .audioTranscode,
                reason: "Re-encode audio with the optional late-night dialogue-focused preset.",
                videoArguments: ["-c:v", "copy"],
                audioArguments: encodedAudio,
                requiresHVC1: video == "hevc", audioProcessingMode: .lateNight))
        }
        steps += encodeSteps(strategy: .hardwareEncode, reason: "Use Apple hardware encoding for broad playback compatibility.",
            videoArguments: h264Encode, requiresHVC1: false,
            requiredTransfer: nil)
        return ConversionPlan(intent: intent, steps: steps, reason: appleTVIssues.isEmpty
            ? "Prepare a compatible MP4 using the least destructive available strategy."
            : AppleTVVideoCompatibility.reason(for: appleTVIssues))
    }
}
