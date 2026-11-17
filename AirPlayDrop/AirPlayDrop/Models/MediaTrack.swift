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

    /// Bitmap subtitle formats (Blu-ray PGS, DVD VobSub, DVB, XSUB). MP4 cannot
    /// carry them, so they are burned into the video instead.
    static let bitmapSubtitleCodecs: Set<String> = ["hdmv_pgs_subtitle", "dvd_subtitle", "dvb_subtitle", "xsub"]

    var isBitmapSubtitle: Bool { kind == .subtitle && Self.bitmapSubtitleCodecs.contains(codec) }

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
    /// The configuration record's `el_present_flag`, set for dual-layer profile 7.
    var dolbyVisionHasEnhancementLayer: Bool? = nil
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
    /// Video stream bit rate in bit/s, from the stream or its Matroska `BPS` tag.
    var videoBitRate: Int? = nil
    /// Whole-file bit rate in bit/s, used when the video stream has none.
    var containerBitRate: Int? = nil

    /// Best available estimate of the source video bit rate. The container
    /// rate includes audio, so it errs high, which is safe for a ceiling.
    var estimatedVideoBitRate: Int? { videoBitRate ?? containerBitRate }
    /// FFprobe `field_order`: `progressive`, or `tt`, `bb`, `tb`, `bt` for interlaced video.
    var fieldOrder: String? = nil

    var isInterlaced: Bool { ["tt", "bb", "tb", "bt"].contains(fieldOrder) }

    /// Frame rate after deinterlacing. Every field becomes a frame, so 25i
    /// becomes 50p and 29.97i becomes 59.94p, as Apple recommends.
    var deinterlacedAverageFrameRate: String? {
        guard isInterlaced, let (numerator, denominator) = AppleTVVideoCompatibility.rational(averageFrameRate),
              numerator > 0 else { return averageFrameRate }
        return "\(numerator * 2)/\(denominator)"
    }

    /// Frames per second, or nil when FFprobe could not determine the rate.
    var frameRate: Double? {
        guard let (numerator, denominator) = AppleTVVideoCompatibility.rational(averageFrameRate),
              numerator > 0 else { return nil }
        return Double(numerator) / Double(denominator)
    }

    /// Profile 7 (UHD Blu-ray) carries an enhancement layer next to its HDR10
    /// base layer. Apple TV supports only single-layer profiles 5 and 8.
    var isDualLayerDolbyVision: Bool {
        isDolbyVision && (dolbyVisionHasEnhancementLayer == true || dolbyVisionProfile == 7)
    }

    /// Profile 5 has no HDR10 or SDR base layer. Its picture is in Dolby's
    /// IPTPQc2 colour space and only looks right once a Dolby Vision decoder
    /// applies the RPU, so it must stay Dolby Vision. Only a probed profile 5
    /// qualifies: an unknown profile keeps the HDR10 base-layer handling.
    var isDolbyVisionProfile5: Bool { isDolbyVision && dolbyVisionProfile == 5 }

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
    /// Render the selected text subtitle into the picture. Bitmap subtitles
    /// are always burned in, because MP4 cannot carry them.
    case burnInSelected

    var label: String {
        switch self {
        case .omit: return "No subtitles"
        case .includeSelected: return "Include selected subtitle"
        case .burnInSelected: return "Burn selected subtitle into video"
        }
    }
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
        subtitlePolicy != .omit && !subtitle.isNone
    }

    /// The policy as it affects the output: no subtitle means nothing to include.
    var effectiveSubtitlePolicy: SubtitlePolicy {
        subtitle.isNone ? .omit : subtitlePolicy
    }
}

enum PlaybackIntent: String, Codable, CaseIterable, Sendable {
    case local
    case airPlay

    var label: String { self == .local ? "This Mac" : "Apple TV / AirPlay" }
}

enum ConversionStrategy: String, Codable, Sendable {
    case directPlay, remux, audioTranscode, hdrRemux, dolbyVisionRemux, hardwareEncode
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
    /// The output must keep a `dvh1` sample entry and Dolby Vision configuration box.
    let requiresDolbyVision: Bool
    /// The subtitle the video arguments draw into the picture. A bitmap
    /// burn-in maps the filter graph's output instead of the source video and
    /// reads the subtitle from a second input; any burn-in drops the subtitle
    /// stream from the output.
    let subtitleBurnIn: SubtitleBurnIn?
    var burnsInSubtitle: Bool { subtitleBurnIn != nil }

    init(strategy: ConversionStrategy, reason: String, videoArguments: [String], audioArguments: [String],
         requiresHVC1: Bool, audioProcessingMode: AudioProcessingMode = .standard,
         requiredTransfer: String? = nil, requiresDolbyVision: Bool = false, subtitleBurnIn: SubtitleBurnIn? = nil) {
        self.strategy = strategy
        self.reason = reason
        self.videoArguments = videoArguments
        self.audioArguments = audioArguments
        self.requiresHVC1 = requiresHVC1
        self.audioProcessingMode = audioProcessingMode
        self.requiredTransfer = requiredTransfer
        self.requiresDolbyVision = requiresDolbyVision
        self.subtitleBurnIn = subtitleBurnIn
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
    static func hevcMain10(for info: MediaInfo, intent: PlaybackIntent = .local,
                           deinterlaceFilter: String? = Deinterlace.filter,
                           burnIn: SubtitleBurnIn? = nil) -> [String] {
        let limits = intent == .airPlay ? AppleTVVideoCompatibility.conformingArguments(for: info)
                                        : (filters: [], output: [])
        return VideoFilterGraph.arguments(pre: Deinterlace.filters(for: info, filter: deinterlaceFilter),
                                          post: limits.filters + [colorFilter(for: info)].compactMap { $0 },
                                          burnIn: burnIn, info: info, outputIsHDR: true)
            + limits.output
            + ["-c:v", "hevc_videotoolbox", "-profile:v", "main10", "-pix_fmt", "p010le",
               "-b:v", "\(VideoBitRate.kilobits(for: info, intent: intent, target: .hevcHDR))k", "-tag:v", "hvc1"]
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

/// A bitmap subtitle stream drawn onto the video during an encode.
struct SubtitleBurnIn: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        /// A bitmap track, overlaid from a second input of the source file.
        case bitmap(streamID: Int)
        /// A text subtitle rendered by libass from a file: the source with the
        /// track's position among its subtitle streams, or a sidecar file.
        case text(path: String, subtitleIndex: Int?, isASS: Bool)
    }

    let source: Source
    /// Subtitle sync offset; positive values show cues later.
    var offsetSeconds: Double = 0

    init(source: Source, offsetSeconds: Double = 0) {
        self.source = source
        self.offsetSeconds = offsetSeconds
    }

    init(streamID: Int, offsetSeconds: Double = 0) {
        self.init(source: .bitmap(streamID: streamID), offsetSeconds: offsetSeconds)
    }

    var isBitmap: Bool {
        if case .bitmap = source { return true }
        return false
    }

    /// The burn-in for the current selection: a bitmap track always, and a
    /// text track or sidecar when the policy asks for burn-in. Embedded text
    /// needs the source path, which libass reads directly.
    static func selected(in info: MediaInfo, selection: TrackSelection,
                         syncAdjustment: SyncAdjustment = .zero, input: URL? = nil) -> SubtitleBurnIn? {
        guard selection.hasSelectedSubtitle else { return nil }
        let offset = Double(syncAdjustment.subtitleMilliseconds) / 1000
        switch selection.subtitle {
        case .embedded(let id):
            guard let track = info.subtitleTracks.first(where: { $0.id == id }) else { return nil }
            if track.isBitmapSubtitle { return SubtitleBurnIn(streamID: id, offsetSeconds: offset) }
            guard selection.subtitlePolicy == .burnInSelected, track.isTextSubtitle, let input,
                  let index = info.subtitleTracks.firstIndex(where: { $0.id == id }) else { return nil }
            return SubtitleBurnIn(source: .text(path: input.path, subtitleIndex: index,
                                                isASS: ["ass", "ssa"].contains(track.codec)), offsetSeconds: offset)
        case .external(let descriptor):
            guard selection.subtitlePolicy == .burnInSelected else { return nil }
            let url = descriptor.standardizedURL
            return SubtitleBurnIn(source: .text(path: url.path, subtitleIndex: nil,
                                                isASS: ["ass", "ssa"].contains(url.pathExtension.lowercased())),
                                  offsetSeconds: offset)
        case .none:
            return nil
        }
    }

    /// Graphics brightness for HDR video. Bitmap subtitles are authored for
    /// SDR, so full-range white would map to peak brightness on PQ (10,000
    /// nits) or HLG video. ITU-R BT.2408 puts graphics white at 203 cd/m²,
    /// which is 58% of the PQ signal range and 75% of the HLG range.
    static func hdrGraphicsScale(for transfer: String?) -> Double? {
        switch transfer {
        case "smpte2084": return 0.58
        case "arib-std-b67": return 0.75
        default: return nil
        }
    }
}

/// Builds the video filter arguments for an encode.
///
/// Without burn-in this is a plain `-vf` chain. With burn-in it is one
/// `-filter_complex` graph whose output `[v]` replaces `0:v:0` in the
/// stream mapping: deinterlace the video, overlay the subtitle, then scale
/// and set the output format or colour tags, so the subtitle is scaled with
/// the picture. The subtitle canvas is centred and bottom-aligned, which keeps
/// cues on screen when a Blu-ray canvas (1920×1080) is taller than a cropped
/// video (for example 1920×800).
///
/// The subtitle is read from a second input of the same file. FFmpeg times
/// bitmap subtitles from the video packets of their own input in decode
/// order, so with B-frames in the source, cues drawn from the first input
/// start late and stay up to 0.2 s too long. A separate input keeps cues
/// frame-accurate without buffering video across long subtitle gaps.
enum VideoFilterGraph {
    static let outputLabel = "[v]"
    static let subtitleInput = 1

    static func arguments(pre: [String], post: [String], burnIn: SubtitleBurnIn?, info: MediaInfo,
                          outputIsHDR: Bool) -> [String] {
        guard let burnIn else {
            let filters = pre + post
            return filters.isEmpty ? [] : ["-vf", filters.joined(separator: ",")]
        }
        if case .text(let path, let index, let isASS) = burnIn.source {
            return ["-vf", (pre + textSubtitleFilters(path: path, subtitleIndex: index, isASS: isASS,
                offsetSeconds: burnIn.offsetSeconds, info: info, outputIsHDR: outputIsHDR) + post)
                .joined(separator: ",")]
        }
        guard case .bitmap(let streamID) = burnIn.source else { return [] }
        var subtitle: [String] = []
        if burnIn.offsetSeconds != 0 {
            subtitle.append("setpts=PTS+\(String(format: "%.3f", burnIn.offsetSeconds))/TB")
        }
        if outputIsHDR, let scale = SubtitleBurnIn.hdrGraphicsScale(for: info.hdrTransfer) {
            subtitle.append("colorchannelmixer=rr=\(scale):gg=\(scale):bb=\(scale)")
        }
        let base = "[0:v:0]" + (pre.isEmpty ? "null" : pre.joined(separator: ",")) + "[base]"
        let sub = "[\(subtitleInput):\(streamID)]" + (subtitle.isEmpty ? "null" : subtitle.joined(separator: ",")) + "[sub]"
        let overlay = "[base][sub]" + (["overlay=x=(W-w)/2:y=H-h:eof_action=pass:format=auto"] + post)
            .joined(separator: ",") + outputLabel
        return ["-filter_complex", [base, sub, overlay].joined(separator: ";")]
    }

    /// libass renders text with `subtitles`, which has no time offset, so the
    /// video timestamps are shifted around it instead. On HDR output, plain
    /// text subtitles (SRT, WebVTT, mov_text) use a dimmed default colour at
    /// BT.2408 graphics white; ASS keeps its authored styles.
    static func textSubtitleFilters(path: String, subtitleIndex: Int?, isASS: Bool, offsetSeconds: Double,
                                    info: MediaInfo, outputIsHDR: Bool) -> [String] {
        var options = "filename=" + FilterEscaping.value(path)
        if let subtitleIndex { options += ":si=\(subtitleIndex)" }
        if outputIsHDR, !isASS, let scale = SubtitleBurnIn.hdrGraphicsScale(for: info.hdrTransfer) {
            let level = String(format: "%02X", Int((255 * scale).rounded()))
            options += ":force_style=" + FilterEscaping.value("PrimaryColour=&H00\(level)\(level)\(level)")
        }
        // libass is built without libunibreak, so Unicode line breaking is off.
        options += ":wrap_unicode=0"
        let shift = offsetSeconds == 0 ? nil : String(format: "%.3f", abs(offsetSeconds))
        let (before, after) = offsetSeconds > 0 ? ("-", "+") : ("+", "-")
        return (shift.map { ["setpts=PTS\(before)\($0)/TB"] } ?? []) + ["subtitles=" + options]
            + (shift.map { ["setpts=PTS\(after)\($0)/TB"] } ?? [])
    }
}

/// FFmpeg filtergraph escaping for option values such as file paths.
///
/// A value is escaped twice: once for the filter's option parser (`\`, `'`
/// and `:`), then for the filtergraph parser (`\`, `'`, `[`, `]`, `,`, `;`),
/// as FFmpeg's filter documentation describes. Arguments are passed to FFmpeg
/// directly, so no shell quoting is involved.
enum FilterEscaping {
    static func value(_ raw: String) -> String {
        graph(option(raw))
    }

    static func option(_ raw: String) -> String {
        escape(raw, characters: ["\\", "'", ":"])
    }

    static func graph(_ raw: String) -> String {
        escape(raw, characters: ["\\", "'", "[", "]", ",", ";"])
    }

    private static func escape(_ raw: String, characters: Set<Character>) -> String {
        var result = ""
        for character in raw {
            if characters.contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }
}

/// Deinterlacing for encodes of interlaced sources.
///
/// Apple's HLS authoring specification says all interlaced content must be
/// deinterlaced, and that 30i should become 60p rather than 30p. `bwdif`
/// (LGPL) outputs one frame per field, which does both. Stream copies keep
/// the source fields: macOS deinterlaces on display, and AirPlay never
/// copies interlaced video.
enum Deinterlace {
    static let filter = "bwdif=mode=send_field:parity=auto:deint=all"

    static func filters(for info: MediaInfo, filter: String?) -> [String] {
        info.isInterlaced ? [filter].compactMap { $0 } : []
    }
}

/// Target bit rates for VideoToolbox encodes.
///
/// The base rates are the highest rung for each resolution in item 1.25 of
/// Apple's HLS authoring specification: the HDR (HEVC) column for HDR
/// encodes and the H.264/AVC column for H.264 encodes. A single AirPlay
/// stream on a home network has no adaptive ladder to fall back on, so it
/// uses the top rung. Rates between rungs are interpolated by pixel count,
/// and larger or smaller frames scale with pixel count. Apple's H.264 column
/// stops at 1080p, so 2160p H.264 is extrapolated to four times the 1080p rate.
///
/// Apple gives the HEVC rates for 30 fps and says 24 fps HEVC should use
/// about 20% less; it gives no figure for higher frame rates, so AirPlayDrop
/// adds half the 30 fps rate at 60 fps for both codecs.
///
/// A re-encode cannot add detail, so the target never exceeds 125% of the
/// source's own bit rate when that is known. H.264 needs roughly twice the
/// rate of HEVC, VP9, or AV1 for similar quality, so encoding one of those
/// to H.264 allows up to 200%.
enum VideoBitRate {
    enum Target: Sendable { case h264, hevcHDR }

    /// (pixels, kbit/s)
    static let hdrLadder: [(pixels: Int, kilobits: Int)] = [
        (960 * 540, 1_930),
        (1280 * 720, 4_080),
        (1920 * 1080, 7_000),
        (2560 * 1440, 9_700),
        (3840 * 2160, 20_000),
    ]
    static let h264Ladder: [(pixels: Int, kilobits: Int)] = [
        (960 * 540, 2_000),
        (1280 * 720, 4_500),
        (1920 * 1080, 7_800),
    ]
    static let minimumKilobits = 500
    static let efficientSourceCodecs: Set<String> = ["hevc", "vp9", "av1"]

    static func kilobits(for info: MediaInfo, intent: PlaybackIntent, target: Target,
                         receiver: AirPlayReceiver = .appleTV4K) -> Int {
        let pixels = outputPixels(for: info, intent: intent, receiver: receiver)
        let ladder = target == .h264 ? h264Ladder : hdrLadder
        var rate = Double(baseKilobits(forPixels: pixels, ladder: ladder))
            * frameRateFactor(outputFrameRate(for: info, intent: intent), target: target)
        if let source = info.estimatedVideoBitRate, source > 0 {
            rate = min(rate, Double(source) / 1000 * sourceHeadroom(for: info, target: target))
        }
        return max(minimumKilobits, Int(rate.rounded()))
    }

    static func sourceHeadroom(for info: MediaInfo, target: Target) -> Double {
        let codec = info.videoCodec?.lowercased() ?? ""
        return target == .h264 && efficientSourceCodecs.contains(codec) ? 2 : 1.25
    }

    static func baseKilobits(forPixels pixels: Int, ladder: [(pixels: Int, kilobits: Int)]) -> Int {
        guard let first = ladder.first, let last = ladder.last else { return 0 }
        if pixels <= first.pixels {
            return Int((Double(first.kilobits) * Double(pixels) / Double(first.pixels)).rounded())
        }
        if pixels >= last.pixels {
            return Int((Double(last.kilobits) * Double(pixels) / Double(last.pixels)).rounded())
        }
        for (lower, upper) in zip(ladder, ladder.dropFirst()) where pixels <= upper.pixels {
            let fraction = Double(pixels - lower.pixels) / Double(upper.pixels - lower.pixels)
            return Int((Double(lower.kilobits) + fraction * Double(upper.kilobits - lower.kilobits)).rounded())
        }
        return last.kilobits
    }

    static func frameRateFactor(_ rate: Double?, target: Target) -> Double {
        guard let rate, rate > 0 else { return 1 }
        // Apple's 24 fps reduction is stated for HEVC only.
        if rate < 24.5 { return target == .hevcHDR ? 0.8 : 1 }
        if rate <= 31 { return 1 }
        return 1 + 0.5 * (rate - 30) / 30
    }

    /// Output pixels after any AirPlay downscale. Unknown sizes use 2160p
    /// so quality is not reduced by a missing probe field.
    static func outputPixels(for info: MediaInfo, intent: PlaybackIntent,
                             receiver: AirPlayReceiver = .appleTV4K) -> Int {
        guard let width = info.width, let height = info.height, width > 0, height > 0 else {
            return 3840 * 2160
        }
        guard intent == .airPlay else { return width * height }
        let scale = min(1, Double(receiver.maxLongSide) / Double(max(width, height)),
                        Double(receiver.maxShortSide) / Double(min(width, height)))
        return Int((Double(width) * scale).rounded()) * Int((Double(height) * scale).rounded())
    }

    static func outputFrameRate(for info: MediaInfo, intent: PlaybackIntent) -> Double? {
        guard let (numerator, denominator) = AppleTVVideoCompatibility.rational(info.deinterlacedAverageFrameRate),
              numerator > 0 else { return nil }
        let rate = Double(numerator) / Double(denominator)
        guard intent == .airPlay, rate > AppleTVVideoCompatibility.frameRateLimit else { return rate }
        return rate / (rate / AppleTVVideoCompatibility.frameRateLimit).rounded(.up)
    }
}

/// The AirPlay receiver video is prepared for. macOS cannot tell which
/// receiver an AirPlay route leads to, so this is a user setting.
enum AirPlayReceiver: String, Codable, CaseIterable, Sendable {
    /// Apple TV 4K or another receiver that decodes HEVC and HDR. An Apple TV
    /// 4K converts HDR itself for SDR televisions.
    case appleTV4K
    /// Apple TV HD or another receiver limited to SDR H.264. Apple's Apple TV
    /// HD specifications list H.264 "up to 1080p, 60 fps", and HEVC only as
    /// SDR up to 1080p at 30 fps, so this profile accepts H.264 SDR only.
    case sdrH264

    var label: String {
        switch self {
        case .appleTV4K: return "Apple TV 4K or HDR receiver"
        case .sdrH264: return "Apple TV HD or SDR-only receiver"
        }
    }

    var maxLongSide: Int { self == .appleTV4K ? 4096 : 1920 }
    var maxShortSide: Int { self == .appleTV4K ? 2160 : 1080 }
    var acceptsHDR: Bool { self == .appleTV4K }
    var codecs: Set<String> { self == .appleTV4K ? ["h264", "hevc"] : ["h264"] }
}

/// HDR to SDR conversion for 8-bit H.264 encodes.
///
/// VideoToolbox's pixel transfer session (FFmpeg's `scale_vt`) converts PQ
/// and HLG to BT.709 with Apple's tone mapping, compressing highlights rather
/// than clipping them. It needs the frames on a VideoToolbox device, so the
/// chain uploads and downloads them, and the encode adds `inputArguments`.
enum ToneMap {
    static let filters = ["format=p010le", "hwupload",
                          "scale_vt=color_matrix=bt709:color_primaries=bt709:color_transfer=bt709",
                          "hwdownload", "format=p010le"]
    static let inputArguments = ["-init_hw_device", "videotoolbox=vt", "-filter_hw_device", "vt"]
    static let requiredFilters = ["hwupload", "scale_vt", "hwdownload"]

    static func isNeeded(for info: MediaInfo) -> Bool { info.hdrTransfer != nil }

    /// Device arguments for a step whose filters tone-map; copy steps get none.
    static func inputArguments(for step: ConversionStep) -> [String] {
        step.videoArguments.contains { $0.contains("scale_vt") } ? inputArguments : []
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
/// "up to 2160p, 60 fps" ceiling. The same HLS specification says all
/// interlaced content must be deinterlaced, so interlaced video is converted.
///
/// The rules are deliberately conservative where they are strict and lenient
/// where probes are unreliable. AV1 and VP9 are always converted for AirPlay:
/// the Apple TV 4K specifications list them, but not every Apple TV decodes
/// them and AirPlay of them is unverified. Levels are not checked because
/// encoders often misreport them, and a false rejection costs a lossy
/// re-encode. Unknown fields and unrecognised profile names count as compatible
/// for the same reason; the pixel format still catches bit depth and chroma.
enum AppleTVVideoCompatibility {
    /// Bump when the rules or the AirPlay video preparation change, so AirPlay
    /// copies prepared earlier are re-prepared. Version 2 strips the Dolby
    /// Vision profile 7 enhancement layer that version 1 copies kept; version 3
    /// deinterlaces video that earlier versions copied.
    static let rulesVersion = 3
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
        case interlaced(String)
        case hdr

        var description: String {
            switch self {
            case .codec(let codec): return "\(codec.uppercased()) video"
            case .profile(let profile): return "the \(profile) profile"
            case .pixelFormat(let format): return "\(format) pixels"
            case .resolution(let width, let height): return "\(width)×\(height) resolution"
            case .frameRate(let rate): return "\(String(format: "%.4g", rate)) fps"
            case .interlaced: return "interlaced video"
            case .hdr: return "HDR video"
            }
        }
    }

    static func issues(for info: MediaInfo, receiver: AirPlayReceiver = .appleTV4K) -> [Issue] {
        guard let codec = info.videoCodec?.lowercased() else { return [] }
        guard let blockedProfiles = unsupportedProfiles[codec], let allowedFormats = pixelFormats[codec] else {
            return [.codec(codec)]
        }
        // A known codec the receiver lacks (HEVC on an SDR receiver) still
        // reports its other issues, so the reason names everything converted.
        var issues: [Issue] = receiver.codecs.contains(codec) ? [] : [.codec(codec)]
        if let profile = info.videoProfile, blockedProfiles.contains(profile) {
            issues.append(.profile(profile))
        }
        if let format = info.pixelFormat, !allowedFormats.contains(format) {
            issues.append(.pixelFormat(format))
        }
        if exceedsResolution(info, receiver: receiver), let width = info.width, let height = info.height {
            issues.append(.resolution(width: width, height: height))
        }
        if let rate = info.frameRate, rate > frameRateLimit {
            issues.append(.frameRate(rate))
        }
        if info.isInterlaced, let order = info.fieldOrder {
            issues.append(.interlaced(order))
        }
        if !receiver.acceptsHDR, info.isHDR {
            issues.append(.hdr)
        }
        return issues
    }

    static func isCompatible(_ info: MediaInfo, receiver: AirPlayReceiver = .appleTV4K) -> Bool {
        issues(for: info, receiver: receiver).isEmpty
    }

    static func reason(for issues: [Issue], receiver: AirPlayReceiver = .appleTV4K) -> String {
        (receiver == .appleTV4K ? "Apple TV" : "The SDR AirPlay receiver") + " cannot play "
            + issues.map(\.description).joined(separator: ", ") + " streamed over AirPlay."
    }

    /// Filters and output options that bring an encode within Apple TV limits.
    static func conformingArguments(for info: MediaInfo, receiver: AirPlayReceiver = .appleTV4K)
        -> (filters: [String], output: [String]) {
        var filters: [String] = []
        if exceedsResolution(info, receiver: receiver), let width = info.width, let height = info.height {
            let (w, h) = width >= height ? (receiver.maxLongSide, receiver.maxShortSide)
                                         : (receiver.maxShortSide, receiver.maxLongSide)
            filters.append("scale=w=\(w):h=\(h):force_original_aspect_ratio=decrease:force_divisible_by=2")
        }
        var output: [String] = []
        // Deinterlacing doubles the frame rate before this cap applies.
        if let (numerator, denominator) = rational(info.deinterlacedAverageFrameRate), numerator > 0,
           case let rate = Double(numerator) / Double(denominator), rate > frameRateLimit {
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

    private static func exceedsResolution(_ info: MediaInfo, receiver: AirPlayReceiver) -> Bool {
        guard let width = info.width, let height = info.height else { return false }
        return max(width, height) > receiver.maxLongSide || min(width, height) > receiver.maxShortSide
    }
}

enum DolbyVisionArguments {
    /// Stream-copies Dolby Vision into a `dvh1` sample entry with its RPUs.
    /// FFmpeg's MP4 muxer writes the `dvcC` configuration box only at
    /// `-strict unofficial`; without it the output is not valid Dolby Vision.
    static let passthrough = ["-c:v", "copy", "-tag:v", "dvh1", "-strict", "unofficial"]
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
                     surroundEncoder: SurroundAudioEncoder = .eac3,
                     deinterlaceFilter: String? = Deinterlace.filter,
                     burnInSubtitle: SubtitleBurnIn? = nil,
                     receiver: AirPlayReceiver = .appleTV4K,
                     canToneMap: Bool = true) -> ConversionPlan {
        let plan = basePlan(info: info, intent: intent, selectedAudioID: selectedAudioID,
                            audioProcessingMode: audioProcessingMode, syncAdjustment: syncAdjustment,
                            requiresSubtitleMuxing: requiresSubtitleMuxing, surroundEncoder: surroundEncoder,
                            deinterlaceFilter: deinterlaceFilter, burnInSubtitle: burnInSubtitle,
                            receiver: intent == .airPlay ? receiver : .appleTV4K, canToneMap: canToneMap)
        guard burnInSubtitle != nil, plan.steps.allSatisfy(\.burnsInSubtitle), !plan.steps.isEmpty else { return plan }
        return ConversionPlan(intent: intent, steps: plan.steps,
            reason: burnInSubtitle?.isBitmap == true
                ? "The selected bitmap subtitle is burned into the video, which needs a full video encode."
                : "The selected subtitle is burned into the video, which needs a full video encode.")
    }

    private static func basePlan(info: MediaInfo, intent: PlaybackIntent, selectedAudioID: Int?,
                                 audioProcessingMode: AudioProcessingMode, syncAdjustment: SyncAdjustment,
                                 requiresSubtitleMuxing: Bool, surroundEncoder: SurroundAudioEncoder,
                                 deinterlaceFilter: String?, burnInSubtitle: SubtitleBurnIn?,
                                 receiver: AirPlayReceiver, canToneMap: Bool) -> ConversionPlan {
        let video = info.videoCodec?.lowercased()
        let appleTVIssues = intent == .airPlay ? AppleTVVideoCompatibility.issues(for: info, receiver: receiver) : []
        // HDR stays HDR (HEVC Main 10) unless the AirPlay receiver is SDR-only.
        let keepsHDR = receiver.acceptsHDR
        // Local playback copies any H.264/HEVC. AirPlay copies only video the Apple TV decodes.
        // A burned-in subtitle needs the video re-encoded for either intent.
        let canCopyVideo = ["h264", "hevc"].contains(video) && appleTVIssues.isEmpty && burnInSubtitle == nil
        let conforming = intent == .airPlay ? AppleTVVideoCompatibility.conformingArguments(for: info, receiver: receiver)
                                            : (filters: [], output: [])
        // The 8-bit H.264 encode tone-maps HDR to BT.709 SDR; without it, the
        // output would be 8-bit video still tagged PQ or HLG.
        let toneMaps = ToneMap.isNeeded(for: info) && canToneMap
        let h264Encode = VideoFilterGraph.arguments(
                pre: Deinterlace.filters(for: info, filter: deinterlaceFilter) + (toneMaps ? ToneMap.filters : []),
                post: conforming.filters + ["format=yuv420p"],
                burnIn: burnInSubtitle, info: info, outputIsHDR: info.hdrTransfer != nil && !toneMaps)
            + conforming.output
            + ["-c:v", "h264_videotoolbox",
               "-b:v", "\(VideoBitRate.kilobits(for: info, intent: intent, target: .h264, receiver: receiver))k"]
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
                    audioProcessingMode: audioProcessingMode, requiredTransfer: requiredTransfer,
                    subtitleBurnIn: burnInSubtitle)
            }
        }

        if audioProcessingMode == .standard, syncAdjustment.isZero, !requiresSubtitleMuxing, burnInSubtitle == nil,
           intent == .local,
           ["mov,mp4,m4a,3gp,3g2,mj2", "mp4", "mov"].contains(info.formatName),
           ["h264", "hevc"].contains(video),
           [nil, "aac", "ac3", "eac3"].contains(audio) {
            return ConversionPlan(intent: intent, steps: [], reason: "The source is already compatible with local playback.")
        }

        // Stripping the RPU, or re-encoding decoded frames (the bundled FFmpeg
        // cannot apply the RPU), would bake in wrong colours. Profile 5 is kept
        // as Dolby Vision, which Apple TV and macOS decode, with no encode
        // fallback: if the copy is rejected, preparation fails with its reason.
        if info.isDolbyVisionProfile5, video == "hevc" {
            var audioVariants = [preferredAudio]
            if preferredAudio != encodedAudio { audioVariants.append(encodedAudio) }
            let reason = "Dolby Vision profile 5 has no HDR10 base layer, so it is kept as Dolby Vision in a dvh1 MP4."
            return ConversionPlan(intent: intent, steps: audioVariants.map {
                ConversionStep(strategy: .dolbyVisionRemux, reason: reason,
                    videoArguments: DolbyVisionArguments.passthrough, audioArguments: $0, requiresHVC1: false,
                    audioProcessingMode: audioProcessingMode, requiredTransfer: info.hdrTransfer,
                    requiresDolbyVision: true)
            }, reason: reason)
        }

        if intent == .airPlay, video == "hevc", info.isHDR, keepsHDR {
            let remux = !canCopyVideo ? [] : [
                // Dolby Vision RPUs are NAL type 62. A single-track dual-layer
                // profile 7 stream also wraps every enhancement-layer NAL,
                // including its own parameter sets, in NAL type 63. Both are
                // unspecified types in plain HEVC, so removing them leaves the
                // HDR10 base layer and changes nothing for other HDR sources.
                ConversionStep(strategy: .hdrRemux,
                    reason: info.isDualLayerDolbyVision
                        ? "Keep the HDR10 base layer, remove the Dolby Vision enhancement layer and RPU data, and create an hvc1 MP4."
                        : "Preserve the HEVC HDR base layer, remove Dolby Vision RPU data, and create an hvc1 MP4.",
                    videoArguments: ["-c:v", "copy", "-bsf:v", "filter_units=remove_types=62|63", "-tag:v", "hvc1"],
                    audioArguments: preferredAudio, requiresHVC1: true,
                    audioProcessingMode: audioProcessingMode, requiredTransfer: info.hdrTransfer)
            ]
            let reason = !appleTVIssues.isEmpty ? AppleTVVideoCompatibility.reason(for: appleTVIssues, receiver: receiver)
                : info.isDualLayerDolbyVision ? "Dual-layer Dolby Vision (profile 7) plays on Apple TV only as its HDR10 base layer."
                : info.isDolbyVision ? "Dolby Vision needs an Apple TV compatible HDR10 fallback."
                : "HDR HEVC needs an AirPlay-safe MP4 sample entry."
            return ConversionPlan(intent: intent, steps: remux + encodeSteps(strategy: .hardwareEncode,
                    reason: "Re-encode HDR as HEVC Main 10 when the lossless HDR remux is rejected.",
                    videoArguments: HDRVideoArguments.hevcMain10(for: info, intent: intent,
                        deinterlaceFilter: deinterlaceFilter, burnIn: burnInSubtitle),
                    requiresHVC1: true, requiredTransfer: info.hdrTransfer), reason: reason)
        }

        // AV1, VP9, and other HDR sources that cannot be stream-copied. The
        // generic H.264 encode would produce 8-bit video still tagged PQ/HLG,
        // so HDR is encoded as HEVC Main 10 instead, with no H.264 fallback.
        if let transfer = info.hdrTransfer, !canCopyVideo, keepsHDR {
            return ConversionPlan(intent: intent, steps: encodeSteps(strategy: .hardwareEncode,
                    reason: "Encode HDR video as HEVC Main 10, keeping its HDR signalling.",
                    videoArguments: HDRVideoArguments.hevcMain10(for: info, intent: intent,
                        deinterlaceFilter: deinterlaceFilter, burnIn: burnInSubtitle),
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
        if audioProcessingMode == .lateNight && steps.isEmpty && intent == .local && burnInSubtitle == nil {
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
            : AppleTVVideoCompatibility.reason(for: appleTVIssues, receiver: receiver))
    }
}
