import Foundation
import Darwin

private final class ProbeProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var timedOut = false

    func install(_ process: Process) {
        lock.lock(); defer { lock.unlock() }
        self.process = process
    }

    func terminate(timedOut: Bool = false) {
        lock.lock()
        cancelled = true
        self.timedOut = self.timedOut || timedOut
        let process = self.process
        lock.unlock()
        guard let process, process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process.isRunning { Darwin.kill(pid, SIGKILL) }
        }
    }

    var terminationReason: Error? {
        lock.lock(); defer { lock.unlock() }
        if timedOut { return FFprobeError.timedOut }
        if cancelled { return CancellationError() }
        return nil
    }
}

private final class BoundedProbeOutput: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()
    private var exceededLimit = false

    init(limit: Int) { self.limit = limit }

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        guard !exceededLimit else { return }
        if data.count + chunk.count > limit {
            exceededLimit = true
            data.removeAll(keepingCapacity: false)
        } else {
            data.append(chunk)
        }
    }

    func snapshot() throws -> Data {
        lock.lock(); defer { lock.unlock() }
        if exceededLimit { throw FFprobeError.outputTooLarge }
        return data
    }
}

enum FFprobeError: LocalizedError {
    case timedOut
    case outputTooLarge

    var errorDescription: String? {
        switch self {
        case .timedOut: return "FFprobe did not finish within 30 seconds."
        case .outputTooLarge: return "FFprobe returned more metadata than AirPlayDrop can safely process."
        }
    }
}

struct FFprobeStream: Codable, Equatable, Sendable {
    let index: Int
    let codec_type: String
    let codec_name: String?
    let codec_long_name: String?
    let channels: Int?
    let channel_layout: String?
    let tags: [String: String]?
    let disposition: [String: Int]?
    let profile: String?
    let pix_fmt: String?
    let color_transfer: String?
    let side_data_list: [FFprobeSideData]?
    var color_primaries: String? = nil
    var color_space: String? = nil
    var width: Int? = nil
    var height: Int? = nil
    var avg_frame_rate: String? = nil
    var bit_rate: String? = nil

    var isForced: Bool { disposition?["forced"] == 1 }
}

/// One entry of an FFprobe `side_data_list`. FFprobe emits a mix of strings and
/// numbers here (for example `rotation`, `max_content`, and `dv_profile` are
/// integers), so only the fields AirPlayDrop uses are decoded. Each field is
/// decoded leniently: an unexpected type drops that field instead of failing
/// the entire probe.
struct FFprobeSideData: Codable, Equatable, Sendable {
    let side_data_type: String?
    let dv_profile: Int?
    let dv_bl_signal_compatibility_id: Int?
    let el_present_flag: Int?
    let rotation: Double?

    init(side_data_type: String?, dv_profile: Int? = nil,
         dv_bl_signal_compatibility_id: Int? = nil, el_present_flag: Int? = nil, rotation: Double? = nil) {
        self.side_data_type = side_data_type
        self.dv_profile = dv_profile
        self.dv_bl_signal_compatibility_id = dv_bl_signal_compatibility_id
        self.el_present_flag = el_present_flag
        self.rotation = rotation
    }

    private enum CodingKeys: String, CodingKey {
        case side_data_type, dv_profile, dv_bl_signal_compatibility_id, el_present_flag, rotation
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        side_data_type = try? values.decodeIfPresent(String.self, forKey: .side_data_type)
        dv_profile = try? values.decodeIfPresent(Int.self, forKey: .dv_profile)
        dv_bl_signal_compatibility_id = try? values.decodeIfPresent(Int.self, forKey: .dv_bl_signal_compatibility_id)
        el_present_flag = try? values.decodeIfPresent(Int.self, forKey: .el_present_flag)
        rotation = try? values.decodeIfPresent(Double.self, forKey: .rotation)
    }

    var isDolbyVisionConfiguration: Bool {
        guard let type = side_data_type else { return dv_profile != nil }
        return type.localizedCaseInsensitiveContains("dolby vision")
            || type.localizedCaseInsensitiveContains("dovi")
    }
}

struct FFprobeFormat: Codable, Equatable, Sendable {
    let format_name: String?
    let duration: String?
    var bit_rate: String? = nil
}

struct FFprobeResult: Codable, Equatable, Sendable {
    let streams: [FFprobeStream]
    let format: FFprobeFormat?
}

enum FFprobeService {
    static func parse(_ data: Data) throws -> FFprobeResult {
        try JSONDecoder().decode(FFprobeResult.self, from: data)
    }

    static func probe(_ url: URL, using installation: FFmpegInstallation) async throws -> MediaInfo {
        let data = try await runProcess(executable: installation.ffprobe,
            arguments: ["-v", "error", "-show_streams", "-show_format", "-of", "json", url.path])
        return mediaInfo(from: try parse(data))
    }

    static func runProcess(executable: URL, arguments: [String], timeout: TimeInterval = 30) async throws -> Data {
        let holder = ProbeProcess()
        let stdoutBuffer = BoundedProbeOutput(limit: 8 * 1_024 * 1_024)
        let stderrBuffer = BoundedProbeOutput(limit: 64 * 1_024)

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let process = Process()
                let stdout = Pipe()
                let stderr = Pipe()
                process.executableURL = executable
                process.arguments = arguments
                process.standardOutput = stdout
                process.standardError = stderr
                holder.install(process)

                stdout.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if !data.isEmpty { stdoutBuffer.append(data) }
                }
                stderr.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if !data.isEmpty { stderrBuffer.append(data) }
                }

                let timeoutWork = DispatchWorkItem { holder.terminate(timedOut: true) }
                process.terminationHandler = { process in
                    timeoutWork.cancel()
                    stdout.fileHandleForReading.readabilityHandler = nil
                    stderr.fileHandleForReading.readabilityHandler = nil
                    stdoutBuffer.append(stdout.fileHandleForReading.readDataToEndOfFile())
                    stderrBuffer.append(stderr.fileHandleForReading.readDataToEndOfFile())
                    do {
                        if let reason = holder.terminationReason { throw reason }
                        let output = try stdoutBuffer.snapshot()
                        let errorData = try stderrBuffer.snapshot()
                        guard process.terminationStatus == 0 else {
                            let message = String(decoding: errorData, as: UTF8.self)
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            throw NSError(domain: "FFprobe", code: Int(process.terminationStatus),
                                userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? "FFprobe failed" : message])
                        }
                        continuation.resume(returning: output)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }

                do {
                    try process.run()
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
                    if Task.isCancelled { holder.terminate() }
                } catch {
                    timeoutWork.cancel()
                    stdout.fileHandleForReading.readabilityHandler = nil
                    stderr.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        }, onCancel: {
            holder.terminate()
        })
    }

    static func mediaInfo(from result: FFprobeResult) -> MediaInfo {
        let video = result.streams.first { $0.codec_type == "video" }
        let tracks = result.streams.compactMap { stream -> MediaTrack? in
            let kind: MediaTrackKind
            switch stream.codec_type {
            case "video": kind = .video
            case "audio": kind = .audio
            case "subtitle": kind = .subtitle
            default: return nil
            }
            let codec = stream.codec_name ?? "unknown"
            let textCodecs = ["subrip", "srt", "mov_text", "webvtt", "ass", "ssa"]
            return MediaTrack(id: stream.index, kind: kind, codec: codec,
                language: stream.tags?["language"], title: stream.tags?["title"], channels: stream.channels,
                isDefault: stream.disposition?["default"] == 1,
                isTextSubtitle: kind == .subtitle && textCodecs.contains(codec),
                isForced: stream.disposition?["forced"] == 1)
        }
        let sideData = video?.side_data_list ?? []
        let dolbyVision = sideData.first(where: \.isDolbyVisionConfiguration)
        return MediaInfo(formatName: result.format?.format_name,
            duration: result.format?.duration.flatMap(Double.init), videoCodec: video?.codec_name,
            videoProfile: video?.profile, pixelFormat: video?.pix_fmt, colorTransfer: video?.color_transfer,
            isDolbyVision: dolbyVision != nil, tracks: tracks,
            dolbyVisionProfile: dolbyVision?.dv_profile,
            dolbyVisionCompatibilityID: dolbyVision?.dv_bl_signal_compatibility_id,
            dolbyVisionHasEnhancementLayer: dolbyVision?.el_present_flag.map { $0 == 1 },
            rotation: sideData.compactMap(\.rotation).first,
            colorPrimaries: video?.color_primaries,
            colorSpace: video?.color_space,
            width: video?.width, height: video?.height,
            averageFrameRate: video?.avg_frame_rate,
            videoBitRate: video.flatMap(streamBitRate),
            containerBitRate: result.format?.bit_rate.flatMap { Int($0) })
    }

    /// MP4 streams carry `bit_rate`; Matroska files muxed by mkvmerge carry a
    /// `BPS` statistics tag instead, sometimes with a language suffix.
    static func streamBitRate(_ stream: FFprobeStream) -> Int? {
        if let rate = stream.bit_rate.flatMap({ Int($0) }) { return rate }
        let tag = stream.tags?.first { $0.key.uppercased() == "BPS" || $0.key.uppercased().hasPrefix("BPS-") }
        return tag.flatMap { Int($0.value) }
    }

    static func preferredAudio(from streams: [FFprobeStream], preferredLanguage: String? = Locale.current.language.languageCode?.identifier) -> FFprobeStream? {
        let audio = streams.filter { $0.codec_type == "audio" }
        let preferences = preferredLanguage.map { [$0] } ?? []
        return preferredAudio(from: audio, preferredLanguages: preferences)
            ?? audio.first(where: { $0.disposition?["default"] == 1 })
            ?? audio.first
    }

    static func preferredAudio(from streams: [FFprobeStream], preferredLanguages: [String]) -> FFprobeStream? {
        let audio = streams.filter { $0.codec_type == "audio" }
        let normalized = PlaybackPreferences.normalizedCodes(preferredLanguages)

        // Exact language matches win over primary-subtag matches. Within each
        // preference, a default stream wins, followed by the first stream in
        // probe order. This makes selection stable for duplicate tracks.
        for exact in [true, false] {
            for preferred in normalized {
                let candidates = audio.filter { stream in
                    guard let language = stream.tags?["language"] else { return false }
                    guard let actual = PlaybackPreferences.normalizedCodes([language]).first else { return false }
                    if exact { return actual == preferred }
                    return actual.split(separator: "-").first.map(String.init) == preferred.split(separator: "-").first.map(String.init)
                }
                if let selected = candidates.first(where: { $0.disposition?["default"] == 1 }) ?? candidates.first {
                    return selected
                }
            }
        }
        return nil
    }

    static func arguments(audioIndex: Int?, subtitleIndex: Int? = nil) -> [String] {
        var args = ["-map", "0:v:0"]
        if let audioIndex { args += ["-map", "0:\(audioIndex)"] }
        if let subtitleIndex { args += ["-map", "0:\(subtitleIndex)"] }
        return args
    }

    static func defaultSelection(from info: MediaInfo,
                                 preferences: PlaybackPreferences = .systemDefault) -> TrackSelection {
        let streams = info.audioTracks.map {
            FFprobeStream(index: $0.id, codec_type: "audio", codec_name: $0.codec, codec_long_name: nil,
                channels: $0.channels, channel_layout: nil, tags: ["language": $0.language].compactMapValues { $0 },
                disposition: ["default": $0.isDefault ? 1 : 0], profile: nil, pix_fmt: nil,
                color_transfer: nil, side_data_list: nil)
        }
        let audioID = preferredAudio(from: streams, preferredLanguages: preferences.preferredAudioLanguages)?.index
            ?? streams.first(where: { $0.disposition?["default"] == 1 })?.index
            ?? streams.first?.index

        let textSubtitles = info.subtitleTracks.filter(\.isTextSubtitle)
        let subtitle: SubtitleSelection
        switch preferences.subtitleDefaultMode {
        case .off:
            subtitle = .none
        case .preferred:
            subtitle = subtitleSelection(from: textSubtitles,
                                         preferredLanguages: preferences.preferredSubtitleLanguages,
                                         forcedOnly: false)
        case .forcedPreferred:
            subtitle = subtitleSelection(from: textSubtitles,
                                         preferredLanguages: preferences.preferredSubtitleLanguages,
                                         forcedOnly: true)
        }
        return TrackSelection(audioID: audioID, subtitle: subtitle,
                              subtitlePolicy: subtitle.isNone ? .omit : .includeSelected)
    }

    static func defaultSelection(from info: MediaInfo, preferredLanguage: String?) -> TrackSelection {
        var preferences = PlaybackPreferences()
        preferences.preferredAudioLanguages = PlaybackPreferences.normalizedCodes(preferredLanguage.map { [$0] } ?? [])
        return defaultSelection(from: info, preferences: preferences)
    }

    private static func subtitleSelection(from tracks: [MediaTrack], preferredLanguages: [String], forcedOnly: Bool) -> SubtitleSelection {
        let candidates = tracks.filter { !forcedOnly || $0.isForced }
        guard !candidates.isEmpty else { return .none }
        let normalized = PlaybackPreferences.normalizedCodes(preferredLanguages)
        for exact in [true, false] {
            for preferred in normalized {
                let matches = candidates.filter { track in
                    guard let language = track.language else { return false }
                    guard let actual = PlaybackPreferences.normalizedCodes([language]).first else { return false }
                    if exact { return actual == preferred }
                    return actual.split(separator: "-").first.map(String.init) == preferred.split(separator: "-").first.map(String.init)
                }
                if let selected = matches.first(where: { $0.isDefault }) ?? matches.first {
                    return .embedded(streamID: selected.id)
                }
            }
        }
        if let selected = candidates.first(where: { $0.isDefault }) ?? candidates.first {
            return .embedded(streamID: selected.id)
        }
        return .none
    }
}
