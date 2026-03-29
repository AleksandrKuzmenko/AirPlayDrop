import SwiftUI

struct MainWindowView: View {
    @State private var store = PlaylistStore()
    @State private var controller = PlaybackController()

    var body: some View {
        VStack(spacing: 0) {
            // Drop zone
            DropZoneView { urls in
                store.add(urls: FileImportService.filter(urls))
            }
            .padding(12)

            Divider()

            // Playlist (left) + video surface (right)
            HSplitView {
                PlaylistView(store: store, onRemove: remove)
                    .frame(minWidth: 180, idealWidth: 220, maxWidth: 300)

                videoSurface
                    .frame(minWidth: 300)
            }
            .frame(minHeight: 260)

            Divider()

            // Play / Stop / Route picker
            PlaybackControlsView(store: store, controller: controller)
        }
        .frame(minWidth: 600, minHeight: 420)
        // Sync playlist selection → PlaybackController
        .onChange(of: store.selectedID) { _, _ in
            controller.prepare(item: store.selectedItem)
        }
        // Wire AVPlayer failure → retranscode pipeline
        .task {
            controller.onPlaybackFailure = { [weak store] item in
                store?.retranscode(item)
            }
        }
        // Open File… (menu / ⌘O)
        .onReceive(NotificationCenter.default.publisher(for: .openFileRequested)) { _ in
            FileImportService.openPanel { urls in
                store.add(urls: FileImportService.filter(urls))
            }
        }
    }

    // MARK: - Sub-views

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

    // MARK: - Actions

    private func remove(_ item: MediaItem) {
        if store.selectedID == item.id { controller.stop() }
        store.remove(item)
    }
}
