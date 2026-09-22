import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct MainWindowView: View {
    @State private var store = PlaylistStore()
    @State private var controller = PlaybackController()
    @State private var isDropTargeted = false
    @State private var showDependencySettings = false
    @State private var showPlaybackSettings = false
    @State private var synchronizationItem: MediaItem?

    var body: some View {
        HSplitView {
            PlaylistView(
                store: store,
                playingItemID: controller.loadedItem?.id,
                onRemove: remove,
                onPlay: play,
                onRetry: { store.retry($0) },
                onPrepare: { store.prepare($0, for: $1) },
                onCancel: { store.cancel($0) },
                onChooseAudio: { store.chooseAudio($1, for: $0) },
                onChooseSubtitle: { store.chooseSubtitle($1, for: $0) },
                onChooseSubtitleSelection: { store.chooseSubtitle($1, for: $0) },
                onAttachSubtitle: { attachSubtitle(to: $0) },
                onSetAudioProcessingMode: { store.setAudioProcessingMode($1, for: $0) },
                onAdjustSynchronization: { synchronizationItem = $0 }
            )
            .frame(minWidth: 220, idealWidth: 280, maxWidth: 380)

            VStack(spacing: 0) {
                videoArea
                    .frame(minWidth: 480, minHeight: 320)
                if controller.loadedItem != nil {
                    Divider()
                    resumeBanner
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
            weak var playbackController = controller
            controller.onPlaybackFailure = { [store] item in
                store.retranscode(item, for: .local)
            }
            controller.onVideoRenderFailure = { [store] item in
                store.retranscode(item, for: .local)
            }
            controller.onAirPlayCompatibilityRequired = { [store] item in
                store.prepare(item, for: .airPlay)
            }
            controller.onEnded = { [store] in
                guard let controller = playbackController, let current = controller.loadedItem else { return }
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
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            controller.flushHistory()
        }
        .sheet(isPresented: $showDependencySettings) { DependencySettingsView() }
        .sheet(isPresented: $showPlaybackSettings) { PlaybackSettingsView() }
        .sheet(item: $synchronizationItem) { item in
            SynchronizationSettingsView(item: item) { adjustment in
                store.setSyncAdjustment(adjustment, for: item)
                synchronizationItem = nil
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

    @ViewBuilder
    private var resumeBanner: some View {
        if let proposal = controller.resumeProposal {
            HStack(spacing: 10) {
                Text("Resume from \(formatTime(proposal.position))?")
                    .font(.callout)
                Button("Resume") { controller.resume() }
                Button("Start Over") { controller.startOver() }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Resume playback from \(formatTime(proposal.position))")
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

            Button { showDependencySettings = true } label: {
                Label("FFmpeg Settings", systemImage: "gearshape")
            }
            .help("Configure and test FFmpeg / FFprobe")

            Button { showPlaybackSettings = true } label: {
                Label("Playback Settings", systemImage: "captions.bubble")
            }
            .help("Preferred languages apply to newly imported videos")
        }

        ToolbarItem {
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

    private func attachSubtitle(to item: MediaItem) {
        FileImportService.openSubtitlePanel { url in
            guard let url else { return }
            _ = store.attachSubtitle(url, to: item)
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

    private func formatTime(_ seconds: Double) -> String {
        let total = max(Int(seconds), 0)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

struct PlaybackSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    private let preferenceStore = PlaybackPreferencesStore()
    @State private var audioLanguages: String
    @State private var subtitleLanguages: String
    @State private var subtitleMode: SubtitleDefaultMode

    init() {
        let preferences = PlaybackPreferencesStore().preferences
        _audioLanguages = State(initialValue: preferences.preferredAudioLanguages.joined(separator: ", "))
        _subtitleLanguages = State(initialValue: preferences.preferredSubtitleLanguages.joined(separator: ", "))
        _subtitleMode = State(initialValue: preferences.subtitleDefaultMode)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Playback").font(.title2.weight(.semibold))
            Text("These language preferences apply to newly imported videos. Per-video track choices remain unchanged.")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Language preferences apply to newly imported videos")
            TextField("Audio languages (en, sr-Latn)", text: $audioLanguages)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Preferred audio languages, in order")
            languageNames(for: audioLanguages)
            TextField("Subtitle languages (en, sr)", text: $subtitleLanguages)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Preferred subtitle languages, in order")
            languageNames(for: subtitleLanguages)
            Picker("Subtitle defaults", selection: $subtitleMode) {
                ForEach(SubtitleDefaultMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .accessibilityLabel("Subtitle default mode for newly imported videos")
            HStack {
                Button("Reset to System Default") {
                    preferenceStore.reset()
                    let value = preferenceStore.preferences
                    audioLanguages = value.preferredAudioLanguages.joined(separator: ", ")
                    subtitleLanguages = ""
                    subtitleMode = .off
                }
                Spacer()
                Button("Save") {
                    preferenceStore.preferences = PlaybackPreferences(
                        preferredAudioLanguages: audioLanguages.split(separator: ",").map(String.init),
                        preferredSubtitleLanguages: subtitleLanguages.split(separator: ",").map(String.init),
                        subtitleDefaultMode: subtitleMode)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 560)
    }

    @ViewBuilder
    private func languageNames(for value: String) -> some View {
        let codes = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if !codes.isEmpty {
            Text(codes.map { Locale.current.localizedString(forLanguageCode: String($0)) ?? String($0) }.joined(separator: ", "))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct SynchronizationSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    let item: MediaItem
    let onSave: (SyncAdjustment) -> Void
    @State private var audioMilliseconds: String
    @State private var subtitleMilliseconds: String

    init(item: MediaItem, onSave: @escaping (SyncAdjustment) -> Void) {
        self.item = item
        self.onSave = onSave
        _audioMilliseconds = State(initialValue: String(item.syncAdjustment.audioMilliseconds))
        _subtitleMilliseconds = State(initialValue: String(item.syncAdjustment.subtitleMilliseconds))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Adjust Synchronization").font(.title2.weight(.semibold))
            Text("Positive values play the selected stream later; negative values play it earlier. Preparation must run again.")
                .foregroundStyle(.secondary)
            TextField("Audio milliseconds", text: $audioMilliseconds)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Audio synchronization offset in milliseconds")
            TextField("Subtitle milliseconds", text: $subtitleMilliseconds)
                .textFieldStyle(.roundedBorder)
                .disabled(!item.trackSelection.hasSelectedSubtitle)
                .accessibilityLabel("Subtitle synchronization offset in milliseconds")
            HStack {
                Button("Reset") {
                    audioMilliseconds = "0"
                    subtitleMilliseconds = "0"
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    onSave(SyncAdjustment(audioMilliseconds: Int(audioMilliseconds) ?? 0,
                                          subtitleMilliseconds: Int(subtitleMilliseconds) ?? 0))
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 440)
    }
}

struct DependencySettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var directory = UserDefaults.standard.string(forKey: FFmpegLocator.configuredDirectoryKey) ?? ""
    @State private var diagnostics: FFmpegDiagnostics?
    @State private var checking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("FFmpeg and FFprobe").font(.title2.weight(.semibold))
            Text("AirPlayDrop uses separately installed FFmpeg tools. Enter the folder containing both executables, or leave it empty to search PATH and common Homebrew locations.")
                .foregroundStyle(.secondary)
            TextField("/opt/homebrew/bin", text: $directory)
                .textFieldStyle(.roundedBorder)
            if checking { ProgressView("Checking tools…") }
            if let diagnostics {
                if let error = diagnostics.error { Text(error).foregroundStyle(.red) }
                if let version = diagnostics.ffmpegVersion { Text(version).font(.caption.monospaced()) }
                if let version = diagnostics.ffprobeVersion { Text(version).font(.caption.monospaced()) }
            }
            HStack {
                Button("Save and Test") {
                    FFmpegLocator.saveConfiguredDirectory(directory)
                    checking = true
                    Task {
                        diagnostics = await FFmpegLocator.diagnose()
                        checking = false
                    }
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 560)
    }
}
