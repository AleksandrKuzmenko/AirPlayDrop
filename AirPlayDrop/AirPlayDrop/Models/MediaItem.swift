import Foundation
import Observation

@Observable
final class MediaItem: Identifiable {
    let id: UUID
    let fileURL: URL
    var displayName: String
    var duration: Double?   // seconds
    var state: MediaItemState

    init(fileURL: URL) {
        self.id = UUID()
        self.fileURL = fileURL
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
