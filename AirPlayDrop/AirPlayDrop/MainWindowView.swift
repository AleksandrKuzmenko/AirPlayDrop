import SwiftUI

struct MainWindowView: View {
    @State private var store = PlaylistStore()
    @State private var controller = PlaybackController()

    var body: some View {
        VStack(spacing: 0) {
            // Drop zone
            DropZoneView { urls in
                let filtered = FileImportService.filter(urls)
                store.add(urls: filtered)
            }
            .padding(12)

            Divider()

            // Playlist + video surface
            HSplitView {
                PlaylistView(store: store, onRemove: remove)
                    .frame(minWidth: 180, idealWidth: 220, maxWidth: 300)

                videoSurface
                    .frame(minWidth: 300)
            }
            .frame(minHeight: 260)

            Divider()

            // Controls bar
            PlaybackControlsView(store: store, controller: controller)
        }
        .frame(minWidth: 600, minHeight: 420)
        // Sync selection → controller
        .onChange(of: store.selectedID) { _, _ in
            syncSelection()
        }
        // Open File… via menu / notification
        .onReceive(NotificationCenter.default.publisher(for: .openFileRequested)) { _ in
            FileImportService.openPanel { urls in
                store.add(urls: FileImportService.filter(urls))
            }
        }
    }

    @ViewBuilder
    private var videoSurface: some View {
        ZStack {
            Color.black
            if controller.loadedItem != nil {
                PlayerContainerView(player: controller.player)
            } else {
                Image(systemName: "tv")
                    .font(.system(size: 40))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func syncSelection() {
        controller.prepare(item: store.selectedItem)
    }

    private func remove(_ item: MediaItem) {
        if store.selectedID == item.id {
            controller.stop()
        }
        store.remove(item)
    }
}
