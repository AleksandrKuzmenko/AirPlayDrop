import Foundation

/// The default behavior for text subtitles when a new video is imported.
enum SubtitleDefaultMode: String, Codable, CaseIterable, Sendable {
    case off
    case forcedPreferred
    case preferred

    var label: String {
        switch self {
        case .off: return "Off"
        case .forcedPreferred: return "Forced preferred"
        case .preferred: return "Preferred"
        }
    }
}

/// Stable, locale-independent playback defaults.  Language codes are stored in
/// normalized form; the UI is free to localize their display names.
struct PlaybackPreferences: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    var preferredAudioLanguages: [String]
    var preferredSubtitleLanguages: [String]
    var subtitleDefaultMode: SubtitleDefaultMode

    var audioLanguages: [String] {
        get { preferredAudioLanguages }
        set { preferredAudioLanguages = Self.normalizedCodes(newValue) }
    }

    var subtitleLanguages: [String] {
        get { preferredSubtitleLanguages }
        set { preferredSubtitleLanguages = Self.normalizedCodes(newValue) }
    }

    init(preferredAudioLanguages: [String] = PlaybackPreferences.systemAudioLanguages,
         preferredSubtitleLanguages: [String] = [],
         subtitleDefaultMode: SubtitleDefaultMode = .off) {
        self.preferredAudioLanguages = Self.normalizedCodes(preferredAudioLanguages)
        self.preferredSubtitleLanguages = Self.normalizedCodes(preferredSubtitleLanguages)
        self.subtitleDefaultMode = subtitleDefaultMode
    }

    /// Convenience spelling for callers that use the shorter property names.
    init(audioLanguages: [String], subtitleLanguages: [String], subtitleMode: SubtitleDefaultMode = .off) {
        self.init(preferredAudioLanguages: audioLanguages,
                  preferredSubtitleLanguages: subtitleLanguages,
                  subtitleDefaultMode: subtitleMode)
    }

    static var systemAudioLanguages: [String] {
        if let code = Locale.current.language.languageCode?.identifier {
            return normalizedCodes([code])
        }
        return []
    }

    static let systemDefault = PlaybackPreferences()

    static func normalizedCodes(_ codes: [String]) -> [String] {
        var seen = Set<String>()
        return codes.compactMap { value in
            let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "_", with: "-")
                .lowercased()
            guard !raw.isEmpty else { return nil }
            var components = raw.split(separator: "-").map(String.init)
            guard let first = components.first else { return nil }
            // Matroska commonly uses ISO-639-2 codes (eng, srp, fra), while
            // macOS preferences normally use ISO-639-1/BCP-47 (en, sr, fr).
            // Foundation canonicalizes both forms to the same primary code.
            components[0] = Locale(identifier: first).language.languageCode?.identifier.lowercased() ?? first
            let code = components.joined(separator: "-")
            guard seen.insert(code).inserted else { return nil }
            return code
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case preferredAudioLanguages
        case preferredSubtitleLanguages
        case subtitleDefaultMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _ = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
        self.init(
            preferredAudioLanguages: try container.decodeIfPresent([String].self, forKey: .preferredAudioLanguages)
                ?? PlaybackPreferences.systemAudioLanguages,
            preferredSubtitleLanguages: try container.decodeIfPresent([String].self, forKey: .preferredSubtitleLanguages)
                ?? [],
            subtitleDefaultMode: try container.decodeIfPresent(SubtitleDefaultMode.self, forKey: .subtitleDefaultMode)
                ?? .off
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.schemaVersion, forKey: .schemaVersion)
        try container.encode(preferredAudioLanguages, forKey: .preferredAudioLanguages)
        try container.encode(preferredSubtitleLanguages, forKey: .preferredSubtitleLanguages)
        try container.encode(subtitleDefaultMode, forKey: .subtitleDefaultMode)
    }
}

/// Injectable persistence for playback preferences.  A single Codable value is
/// used so adding fields remains atomic and corrupt data can safely fall back
/// to defaults.
final class PlaybackPreferencesStore: @unchecked Sendable {
    static let defaultsKey = "AirPlayDrop.playbackPreferences.v1"

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var preferences: PlaybackPreferences {
        get {
            guard let data = defaults.data(forKey: Self.defaultsKey),
                  let value = try? decoder.decode(PlaybackPreferences.self, from: data) else {
                return .systemDefault
            }
            return value
        }
        set {
            guard let data = try? encoder.encode(newValue) else { return }
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    func reset() { preferences = .systemDefault }
}

typealias PlaybackPreferenceStore = PlaybackPreferencesStore
