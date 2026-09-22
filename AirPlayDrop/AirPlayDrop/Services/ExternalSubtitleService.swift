import Foundation

/// Local-only sidecar discovery. The service deliberately does not recurse or
/// perform network access; a subtitle must live beside the imported video.
enum ExternalSubtitleService {
    static let supportedExtensions: Set<String> = ["srt", "vtt", "ass", "ssa"]

    static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    static func discover(for videoURL: URL, preferences: PlaybackPreferences = .systemDefault,
                         fileManager: FileManager = .default) -> [ExternalSubtitleDescriptor] {
        let directory = videoURL.deletingLastPathComponent()
        guard let urls = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [
            .fileSizeKey, .contentModificationDateKey
        ], options: [.skipsHiddenFiles]) else { return [] }

        let base = videoURL.deletingPathExtension().lastPathComponent
        let lowerBase = base.lowercased()
        let found = urls.compactMap { url -> (ExternalSubtitleDescriptor, Int, Int)? in
            guard isSupported(url) else { return nil }
            let stem = url.deletingPathExtension().lastPathComponent
            let lowerStem = stem.lowercased()
            guard lowerStem == lowerBase || lowerStem.hasPrefix(lowerBase + ".") else { return nil }
            let suffix = String(stem.dropFirst(base.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let language = validLanguageCode(suffix)
            guard let descriptor = ExternalSubtitleDescriptor.make(url: url, language: language) else { return nil }
            let exactRank = lowerStem == lowerBase ? 0 : 1
            let languageRank = language.map { preferences.preferredSubtitleLanguages.firstIndex(of: $0) ?? 10_000 } ?? 10_001
            return (descriptor, exactRank, languageRank)
        }

        var seen = Set<URL>()
        return found.sorted {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            if $0.2 != $1.2 { return $0.2 < $1.2 }
            return $0.0.url.path.localizedStandardCompare($1.0.url.path) == .orderedAscending
        }.compactMap { value in
            let url = value.0.standardizedURL
            guard seen.insert(url).inserted else { return nil }
            return value.0
        }
    }

    static func descriptor(for url: URL) -> ExternalSubtitleDescriptor? {
        guard isSupported(url) else { return nil }
        let stem = url.deletingPathExtension().lastPathComponent
        let pieces = stem.split(separator: ".", omittingEmptySubsequences: true)
        let suffix = pieces.count > 1 ? String(pieces.last!) : nil
        return ExternalSubtitleDescriptor.make(url: url, language: validLanguageCode(suffix ?? ""))
    }

    static func validLanguageCode(_ value: String) -> String? {
        let code = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !code.isEmpty else { return nil }
        // ISO language tags encountered in sidecars are normally ISO-639-1 or
        // ISO-639-2, optionally with a regional subtag.
        let pieces = code.split(separator: "-")
        guard (pieces.count == 1 && (pieces[0].count == 2 || pieces[0].count == 3)) ||
                (pieces.count == 2 && (pieces[0].count == 2 || pieces[0].count == 3) && pieces[1].count == 2) else {
            return nil
        }
        guard pieces.allSatisfy({ $0.allSatisfy { $0.isLetter } }) else { return nil }
        return code
    }

    static func preferred(_ descriptors: [ExternalSubtitleDescriptor], preferences: PlaybackPreferences) -> ExternalSubtitleDescriptor? {
        for code in preferences.preferredSubtitleLanguages {
            if let exact = descriptors.first(where: { $0.language == code }) { return exact }
            let primary = code.split(separator: "-").first.map(String.init)
            if let match = descriptors.first(where: {
                $0.language?.split(separator: "-").first.map(String.init) == primary
            }) { return match }
        }
        return descriptors.first
    }
}
