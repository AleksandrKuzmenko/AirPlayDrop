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
                    .frame(minWidth: 180, idealWidth: 300, maxWidth: 350)

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
                // Audio codec incompatible — skip remux, try audio-transcode (AAC).
                store?.retranscode(item, startingAt: 1)
            }
            controller.onVideoRenderFailure = { [weak store] item in
                // Video codec not renderable — skip remux + audio-transcode, full re-encode to H.264.
                store?.retranscode(item, startingAt: 2)
            }
        }
        // Open File… (menu / ⌘O)
        .onReceive(NotificationCenter.default.publisher(for: .openFileRequested)) { _ in
            FileImportService.openPanel { urls in
                store.add(urls: FileImportService.filter(urls))
            }
        }
        .alert(
            "Transcode Required",
            isPresented: Binding(
                get: { store.transcodeRequest != nil },
                set: { if !$0 { store.confirmTranscode(false) } }
            )
        ) {
            Button("Transcode") { store.confirmTranscode(true) }
            Button("Cancel", role: .cancel) { store.confirmTranscode(false) }
        } message: {
            if let req = store.transcodeRequest {
                Text("""
                '\(req.item.displayName)' needs to be transcoded before it can be cast via AirPlay.

                The result will be saved as '\(req.outputURL.lastPathComponent)' in the same folder. \
                This may take several minutes for large files.
                """)
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
