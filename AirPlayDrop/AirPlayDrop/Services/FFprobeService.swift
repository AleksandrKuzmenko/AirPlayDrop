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
}

struct FFprobeResult: Codable, Equatable, Sendable {
    let streams: [FFprobeStream]
}

enum FFprobeService {
    static func parse(_ data: Data) throws -> FFprobeResult {
        try JSONDecoder().decode(FFprobeResult.self, from: data)
    }

    static func preferredAudio(from streams: [FFprobeStream], preferredLanguage: String? = Locale.current.language.languageCode?.identifier) -> FFprobeStream? {
        let audio = streams.filter { $0.codec_type == "audio" }
        return audio.first(where: { $0.disposition?["default"] == 1 })
            ?? audio.first(where: { $0.tags?["language"]?.lowercased() == preferredLanguage?.lowercased() })
            ?? audio.first
    }

    static func arguments(audioIndex: Int?, subtitleIndex: Int? = nil) -> [String] {
        var args = ["-map", "0:v:0"]
        if let audioIndex { args += ["-map", "0:\(audioIndex)"] }
        if let subtitleIndex { args += ["-map", "0:\(subtitleIndex)"] }
        return args
    }
}
