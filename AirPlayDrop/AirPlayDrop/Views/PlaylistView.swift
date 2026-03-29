import SwiftUI

struct PlaylistView: View {
    @Bindable var store: PlaylistStore
    let onRemove: (MediaItem) -> Void

    var body: some View {
        if store.items.isEmpty {
            Text("No files added")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(store.items, selection: $store.selectedID) { item in
                PlaylistRowView(item: item)
                    .tag(item.id)
                    .contextMenu {
                        Button("Remove") { onRemove(item) }
                    }
            }
            .listStyle(.sidebar)
        }
    }
}

struct PlaylistRowView: View {
    let item: MediaItem

    var body: some View {
        HStack(spacing: 6) {
            stateIndicator
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .font(.body)
                if let dur = item.durationString {
                    Text(dur)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            trailingLabel
        }
        .padding(.vertical, 2)
    }

    // MARK: - Sub-views

    @ViewBuilder
    private var stateIndicator: some View {
        switch item.state {
        case .loading:
            ProgressView()
                .scaleEffect(0.6)
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

    @ViewBuilder
    private var trailingLabel: some View {
        if case .transcoding(let progress) = item.state {
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .frame(width: 60)
                .tint(.orange)
        } else if !item.state.displayLabel.isEmpty {
            Text(item.state.displayLabel)
                .font(.caption2)
                .foregroundStyle(labelColor)
        }
    }

    private var labelColor: Color {
        switch item.state {
        case .unsupported, .failed: return .red
        default: return .secondary
        }
    }
}

/// Rotating icon for transcoding state — uses plain rotation to stay on macOS 14+.
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
