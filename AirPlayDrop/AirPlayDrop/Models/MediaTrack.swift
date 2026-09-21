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
}

struct TrackSelection: Codable, Equatable, Sendable {
    var audioID: Int?
    var subtitleID: Int?
}

enum ConversionProfile: String, Codable, Sendable { case localPlayback, appleTV4KHDR, maximumCompatibilitySDR }
enum ConversionStrategy: String, Codable, Sendable { case directPlay, remux, audioTranscode, hdrRemux, hardwareEncode, softwareEncode }

struct ConversionPlan: Equatable, Sendable {
    let profile: ConversionProfile
    let strategy: ConversionStrategy
    let reasons: [String]
    let estimatedWork: String
}

enum TranscodePlanner {
    static func plan(videoCodec: String, audioCodec: String?, isHDR: Bool, profile: ConversionProfile) -> ConversionPlan {
        switch profile {
        case .localPlayback:
            return ConversionPlan(profile: profile, strategy: .directPlay, reasons: ["Source is delegated to AVFoundation"], estimatedWork: "none")
        case .appleTV4KHDR where isHDR && videoCodec.lowercased() == "hevc":
            return ConversionPlan(profile: profile, strategy: .hdrRemux, reasons: ["Preserve HEVC Main 10 HDR base and normalize the MP4 sample entry"], estimatedWork: "fast remux")
        case .appleTV4KHDR:
            return ConversionPlan(profile: profile, strategy: .hardwareEncode, reasons: ["Source video is not a known Apple TV HDR input"], estimatedWork: "full encode")
        case .maximumCompatibilitySDR where videoCodec.lowercased() == "h264" && (audioCodec == "aac" || audioCodec == nil):
            return ConversionPlan(profile: profile, strategy: .remux, reasons: ["Video and audio are already compatible"], estimatedWork: "fast remux")
        default:
            return ConversionPlan(profile: profile, strategy: .softwareEncode, reasons: ["Normalize video and audio for broad compatibility"], estimatedWork: "full encode")
        }
    }
}
