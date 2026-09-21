import SwiftUI
import UniformTypeIdentifiers

struct MainWindowView: View {
    @State private var store = PlaylistStore()
    @State private var controller = PlaybackController()
    @State private var isDropTargeted = false

    var body: some View {
        HSplitView {
            PlaylistView(
                store: store,
                playingItemID: controller.loadedItem?.id,
                onRemove: remove,
                onPlay: play,
                onRetry: { store.retry($0) },
                onForceTranscode: { store.forceTranscode($0) }
            )
            .frame(minWidth: 220, idealWidth: 280, maxWidth: 380)

            VStack(spacing: 0) {
                videoArea
                    .frame(minWidth: 480, minHeight: 320)
                if controller.loadedItem != nil {
                    Divider()
                    TransportBarView(controller: controller)
                }
            }
        }
        .frame(minWidth: 820, minHeight: 520)
        .toolbar { toolbarContent }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            FileImportService.extractURLs(from: providers) { urls in
                store.add(urls: FileImportService.filter(urls))
            }
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(3)
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: store.selectedID) { _, _ in
            controller.prepare(item: store.selectedItem)
        }
        .task {
            controller.onPlaybackFailure = { [weak store] item in
                store?.retranscode(item, startingAt: 1)
            }
            controller.onVideoRenderFailure = { [weak store] item in
                store?.retranscode(item, startingAt: 2)
            }
            controller.onEnded = { [weak store, weak controller] in
                guard let store, let controller, let current = controller.loadedItem else { return }
                if let next = store.nextReadyItem(after: current) {
                    store.selectedID = next.id
                    controller.prepare(item: next)
                    controller.play()
                } else {
                    controller.stop()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openFileRequested)) { _ in
            openFiles()
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

    // MARK: - Video area

    @ViewBuilder
    private var videoArea: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                Color.black
                if controller.loadedItem != nil {
                    PlayerContainerView(player: controller.player)
                } else if store.items.isEmpty {
                    dropPrompt
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "tv")
                            .font(.system(size: 52))
                            .foregroundStyle(.tertiary)
                        Text(selectionHint)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if controller.isExternalPlaybackActive {
                Label("Streaming via AirPlay", systemImage: "airplayvideo")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.blue, in: Capsule())
                    .padding(12)
            }
        }
    }

    private var selectionHint: String {
        if let item = store.selectedItem {
            switch item.state {
            case .loading:     return "Loading…"
            case .transcoding: return "Transcoding…"
            case .unsupported: return "Waiting for transcode"
            case .failed:      return "Playback failed"
            default:           return "Select a video to play"
            }
        }
        return "Select a video to play"
    }

    private var dropPrompt: some View {
        VStack(spacing: 10) {
            Image(systemName: "film.stack")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Drop video files anywhere")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("or press ⌘O to choose")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button { openFiles() } label: {
                Label("Add Files", systemImage: "plus")
            }
            .help("Add videos (⌘O)")

            Button {
                controller.togglePlayPause()
            } label: {
                Label(
                    controller.isPlaying ? "Pause" : "Play",
                    systemImage: controller.isPlaying ? "pause.fill" : "play.fill"
                )
            }
            .disabled(!canPlay)
            .help(controller.isPlaying ? "Pause (Space)" : "Play (Space)")
            .keyboardShortcut(.space, modifiers: [])

            Button {
                controller.stop()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .disabled(controller.loadedItem == nil)

            Spacer()

            RoutePickerRepresentable()
                .frame(width: 32, height: 28)
                .help("AirPlay / Output device")

            Button(role: .destructive) {
                controller.stop()
                store.removeAll()
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .disabled(store.items.isEmpty)
            .help("Remove all from playlist")
        }
    }

    // MARK: - Computed

    private var canPlay: Bool {
        guard let item = store.selectedItem else { return false }
        return item.state == .ready
    }

    // MARK: - Actions

    private func openFiles() {
        FileImportService.openPanel { urls in
            store.add(urls: FileImportService.filter(urls))
        }
    }

    private func play(_ item: MediaItem) {
        controller.prepare(item: item)
        controller.play()
    }

    private func remove(_ item: MediaItem) {
        if store.selectedID == item.id { controller.stop() }
        store.remove(item)
    }
}
