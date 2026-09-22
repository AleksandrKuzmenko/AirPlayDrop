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
    let side_data_list: [[String: String]]?

    var isForced: Bool { disposition?["forced"] == 1 }
}

struct FFprobeFormat: Codable, Equatable, Sendable {
    let format_name: String?
    let duration: String?
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
        let isDV = sideData.contains { values in
            values.values.contains { $0.localizedCaseInsensitiveContains("dolby vision") || $0.localizedCaseInsensitiveContains("dovi") }
        }
        return MediaInfo(formatName: result.format?.format_name,
            duration: result.format?.duration.flatMap(Double.init), videoCodec: video?.codec_name,
            videoProfile: video?.profile, pixelFormat: video?.pix_fmt, colorTransfer: video?.color_transfer,
            isDolbyVision: isDV, tracks: tracks)
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
