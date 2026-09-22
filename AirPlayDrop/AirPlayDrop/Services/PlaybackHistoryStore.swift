import Foundation

struct PlaybackSourceIdentity: Codable, Equatable, Hashable, Sendable {
    let standardizedPath: String
    let fileSize: Int64
    let modificationDate: Date?

    var key: String {
        let date = modificationDate?.timeIntervalSince1970.description ?? "-"
        return "\(standardizedPath)|\(fileSize)|\(date)"
    }

    static func make(for url: URL, fileManager: FileManager = .default) -> PlaybackSourceIdentity? {
        let standardized = url.standardizedFileURL
        guard let values = try? standardized.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize else { return nil }
        return PlaybackSourceIdentity(standardizedPath: standardized.path,
                                      fileSize: Int64(size), modificationDate: values.contentModificationDate)
    }
}

struct PlaybackHistoryEntry: Codable, Equatable, Sendable {
    let identity: PlaybackSourceIdentity
    let position: Double
    let duration: Double
    let updatedAt: Date

    var isEligible: Bool {
        PlaybackHistoryStore.isEligible(position: position, duration: duration)
    }
}

protocol PlaybackHistoryStoring: AnyObject {
    func entry(for sourceURL: URL) -> PlaybackHistoryEntry?
    func save(sourceURL: URL, position: Double, duration: Double, at date: Date)
    func clear(sourceURL: URL)
    func clear(identity: PlaybackSourceIdentity)
}

final class PlaybackHistoryStore: PlaybackHistoryStoring, @unchecked Sendable {
    static let defaultsKey = "AirPlayDrop.playbackHistory.v1"
    static let schemaVersion = 1
    static let maximumEntries = 100

    private struct Payload: Codable {
        let schemaVersion: Int
        let entries: [PlaybackHistoryEntry]
    }

    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard, fileManager: FileManager = .default) {
        self.defaults = defaults
        self.fileManager = fileManager
    }

    static func identity(for sourceURL: URL, fileManager: FileManager = .default) -> PlaybackSourceIdentity? {
        PlaybackSourceIdentity.make(for: sourceURL, fileManager: fileManager)
    }

    static func isEligible(position: Double, duration: Double?) -> Bool {
        guard position.isFinite, let duration, duration.isFinite,
              position >= 30, duration > 0, duration - position >= 60 else { return false }
        return true
    }

    func entry(for sourceURL: URL) -> PlaybackHistoryEntry? {
        guard let identity = Self.identity(for: sourceURL, fileManager: fileManager) else { return nil }
        return load().first(where: { $0.identity == identity && $0.position.isFinite && $0.duration.isFinite })
    }

    func position(for sourceURL: URL) -> PlaybackHistoryEntry? { entry(for: sourceURL) }

    func save(sourceURL: URL, position: Double, duration: Double, at date: Date = Date()) {
        guard let identity = Self.identity(for: sourceURL, fileManager: fileManager),
              position.isFinite, duration.isFinite, position >= 0, duration > 0,
              date.timeIntervalSince1970.isFinite else { return }
        var entries = load().filter { $0.identity != identity }
        entries.append(PlaybackHistoryEntry(identity: identity, position: position, duration: duration, updatedAt: date))
        entries.sort { $0.updatedAt > $1.updatedAt }
        write(Array(entries.prefix(Self.maximumEntries)))
    }

    func record(sourceURL: URL, position: Double, duration: Double, at date: Date = Date()) {
        save(sourceURL: sourceURL, position: position, duration: duration, at: date)
    }

    func clear(sourceURL: URL) {
        guard let identity = Self.identity(for: sourceURL, fileManager: fileManager) else { return }
        clear(identity: identity)
    }

    func remove(sourceURL: URL) { clear(sourceURL: sourceURL) }

    func clear(identity: PlaybackSourceIdentity) {
        write(load().filter { $0.identity != identity })
    }

    func removeAll() { write([]) }

    private func load() -> [PlaybackHistoryEntry] {
        lock.lock(); defer { lock.unlock() }
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.schemaVersion == Self.schemaVersion else { return [] }
        return payload.entries.filter {
            $0.position.isFinite && $0.duration.isFinite && $0.position >= 0 && $0.duration > 0 &&
            $0.updatedAt.timeIntervalSince1970.isFinite
        }
    }

    private func write(_ entries: [PlaybackHistoryEntry]) {
        lock.lock(); defer { lock.unlock() }
        let payload = Payload(schemaVersion: Self.schemaVersion, entries: Array(entries.prefix(Self.maximumEntries)))
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

struct PlaybackResumeProposal: Equatable, Sendable {
    let position: Double
    let duration: Double

    var remaining: Double { max(duration - position, 0) }
}
