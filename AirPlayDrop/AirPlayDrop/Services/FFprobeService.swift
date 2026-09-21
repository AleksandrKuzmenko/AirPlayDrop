import Foundation

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
        let data = try await Task.detached {
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            process.executableURL = installation.ffprobe
            process.arguments = ["-v", "error", "-show_streams", "-show_format", "-of", "json", url.path]
            process.standardOutput = stdout
            process.standardError = stderr
            try process.run()
            let result = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let message = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                throw NSError(domain: "FFprobe", code: Int(process.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? "FFprobe failed" : message])
            }
            return result
        }.value
        return mediaInfo(from: try parse(data))
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
                isTextSubtitle: kind == .subtitle && textCodecs.contains(codec))
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
        return audio.first(where: { $0.disposition?["default"] == 1 && $0.tags?["language"]?.lowercased() == preferredLanguage?.lowercased() })
            ?? audio.first(where: { $0.disposition?["default"] == 1 })
            ?? audio.first(where: { $0.tags?["language"]?.lowercased() == preferredLanguage?.lowercased() })
            ?? audio.first
    }

    static func arguments(audioIndex: Int?, subtitleIndex: Int? = nil) -> [String] {
        var args = ["-map", "0:v:0"]
        if let audioIndex { args += ["-map", "0:\(audioIndex)"] }
        if let subtitleIndex { args += ["-map", "0:\(subtitleIndex)"] }
        return args
    }

    static func defaultSelection(from info: MediaInfo, preferredLanguage: String? = Locale.current.language.languageCode?.identifier) -> TrackSelection {
        let streams = info.audioTracks.map {
            FFprobeStream(index: $0.id, codec_type: "audio", codec_name: $0.codec, codec_long_name: nil,
                channels: $0.channels, channel_layout: nil, tags: ["language": $0.language].compactMapValues { $0 },
                disposition: ["default": $0.isDefault ? 1 : 0], profile: nil, pix_fmt: nil,
                color_transfer: nil, side_data_list: nil)
        }
        return TrackSelection(audioID: preferredAudio(from: streams, preferredLanguage: preferredLanguage)?.index,
            subtitleID: nil, subtitlePolicy: .omit)
    }
}
