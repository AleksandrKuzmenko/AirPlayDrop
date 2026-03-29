import Foundation
import Observation

// @unchecked Sendable: all mutations occur on @MainActor; the class itself is not
// actor-isolated, but access patterns in this app guarantee main-thread safety.
@Observable
final class MediaItem: Identifiable, @unchecked Sendable {
    let id: UUID
    let fileURL: URL        // original source; never changes
    var transcodedURL: URL? // set by TranscodeService on success
    var displayName: String
    var duration: Double?   // seconds, best-effort
    var state: MediaItemState

    /// URL handed to AVPlayer — prefers the transcoded copy when available.
    var playbackURL: URL { transcodedURL ?? fileURL }

    init(fileURL: URL) {
        self.id = UUID()
        self.fileURL = fileURL
        self.transcodedURL = nil
        self.displayName = fileURL.deletingPathExtension().lastPathComponent
        self.duration = nil
        self.state = .idle
    }

    var durationString: String? {
        guard let d = duration, d > 0 else { return nil }
        let total = Int(d)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
