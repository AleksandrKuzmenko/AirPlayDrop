import Foundation
import Observation

@Observable
@MainActor
final class PlaylistStore {
    var items: [MediaItem] = []
    var selectedID: UUID?

    var selectedItem: MediaItem? {
        guard let id = selectedID else { return nil }
        return items.first { $0.id == id }
    }

    func add(urls: [URL]) {
        for url in urls {
            guard !items.contains(where: { $0.fileURL.standardizedFileURL == url.standardizedFileURL }) else {
                continue
            }
            let item = MediaItem(fileURL: url)
            items.append(item)
            Task {
                await MetadataLoader.load(item: item)
                // Auto-select first ready item when nothing is selected
                if selectedID == nil, item.state == .ready {
                    selectedID = item.id
                }
            }
        }
    }

    func remove(_ item: MediaItem) {
        items.removeAll { $0.id == item.id }
        if selectedID == item.id {
            selectedID = items.first { $0.state == .ready }?.id
        }
    }

    func select(_ item: MediaItem) {
        selectedID = item.id
    }
}
