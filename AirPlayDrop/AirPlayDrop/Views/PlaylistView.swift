import SwiftUI

struct PlaylistView: View {
    @Bindable var store: PlaylistStore
    let playingItemID: UUID?
    let onRemove: (MediaItem) -> Void
    let onPlay: (MediaItem) -> Void
    let onRetry: (MediaItem) -> Void
    let onPrepare: (MediaItem, PlaybackIntent) -> Void
    let onCancel: (MediaItem) -> Void
    let onChooseAudio: (MediaItem, Int?) -> Void
    let onChooseSubtitle: (MediaItem, Int?) -> Void

    var body: some View {
        Group {
            if store.items.isEmpty {
                emptyState
            } else {
                playlist
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "music.note.list")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("Playlist is empty")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Drop videos or press ⌘O")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var playlist: some View {
        List(selection: $store.selectedID) {
            ForEach(store.items) { item in
                PlaylistRowView(item: item, isPlaying: item.id == playingItemID)
                    .tag(item.id)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        store.selectedID = item.id
                        onPlay(item)
                    }
                    .contextMenu {
                        Button("Play") {
                            store.selectedID = item.id
                            onPlay(item)
                        }
                        .disabled(item.state != .ready)

                        Button("Retry Transcode") { onRetry(item) }
                            .disabled(item.state == .loading)

                        Menu("Prepare for") {
                            Button("This Mac") { onPrepare(item, .local) }
                            Button("Apple TV / AirPlay") { onPrepare(item, .airPlay) }
                        }
                        .disabled(item.state == .loading)

                        if case .transcoding = item.state {
                            Button("Cancel Preparation", role: .destructive) { onCancel(item) }
                        }

                        if let info = item.mediaInfo, !info.audioTracks.isEmpty {
                            Menu("Audio Track") {
                                ForEach(info.audioTracks) { track in
                                    Button {
                                        onChooseAudio(item, track.id)
                                    } label: {
                                        if item.trackSelection.audioID == track.id {
                                            Label(track.displayName, systemImage: "checkmark")
                                        } else { Text(track.displayName) }
                                    }
                                }
                            }
                        }

                        if let info = item.mediaInfo, !info.subtitleTracks.isEmpty {
                            Menu("Subtitles") {
                                Button {
                                    onChooseSubtitle(item, nil)
                                } label: {
                                    if item.trackSelection.subtitleID == nil { Label("None", systemImage: "checkmark") }
                                    else { Text("None") }
                                }
                                ForEach(info.subtitleTracks.filter(\.isTextSubtitle)) { track in
                                    Button {
                                        onChooseSubtitle(item, track.id)
                                    } label: {
                                        if item.trackSelection.subtitleID == track.id {
                                            Label(track.displayName, systemImage: "checkmark")
                                        } else { Text(track.displayName) }
                                    }
                                }
                            }
                        }

                        Divider()

                        Button("Remove", role: .destructive) { onRemove(item) }
                    }
            }
            .onMove { source, destination in
                store.move(fromOffsets: source, toOffset: destination)
            }
        }
        .listStyle(.sidebar)
        .onDeleteCommand {
            guard let id = store.selectedID,
                  let item = store.items.first(where: { $0.id == id }) else { return }
            onRemove(item)
        }
    }
}

struct PlaylistRowView: View {
    let item: MediaItem
    let isPlaying: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                stateIndicator
                    .frame(width: 14, alignment: .center)

                Text(item.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .font(.body)

                Spacer(minLength: 4)

                if let tag = item.formatTag {
                    Text(tag)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.orange, in: Capsule())
                        .help("\(tag) source — AirPlay may show audio only. Right-click → Force Transcode for AirPlay.")
                }

                if let dur = item.durationString {
                    Text(dur)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            if case .transcoding(let progress) = item.state {
                ProgressView(value: max(progress, 0.01))
                    .progressViewStyle(.linear)
                    .controlSize(.mini)
                    .tint(.orange)
                if let reason = item.preparationReason {
                    Text(reason).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            } else if case .failed = item.state, let msg = item.state.errorDescription {
                Text(msg)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else if let reason = item.preparationReason {
                Text(reason).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var stateIndicator: some View {
        if isPlaying {
            Image(systemName: "speaker.wave.2.fill")
                .foregroundStyle(Color.accentColor)
                .font(.caption)
        } else {
            switch item.state {
            case .loading:
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 14, height: 14)
            case .transcoding:
                SpinningIcon()
            case .unsupported, .failed:
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
                    .help(item.state.errorDescription ?? "Cannot play this file")
            default:
                Image(systemName: "film")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
    }
}

private struct SpinningIcon: View {
    @State private var degrees = 0.0

    var body: some View {
        Image(systemName: "arrow.triangle.2.circlepath")
            .foregroundStyle(.orange)
            .font(.caption)
            .rotationEffect(.degrees(degrees))
            .onAppear {
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    degrees = 360
                }
            }
    }
}
