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
            if !item.state.displayLabel.isEmpty {
                Text(item.state.displayLabel)
                    .font(.caption2)
                    .foregroundStyle(labelColor)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var stateIndicator: some View {
        switch item.state {
        case .loading:
            ProgressView()
                .scaleEffect(0.6)
                .frame(width: 14, height: 14)
        case .unsupported, .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .font(.caption)
        default:
            Image(systemName: "film")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }

    private var labelColor: Color {
        switch item.state {
        case .unsupported, .failed: return .red
        default: return .secondary
        }
    }
}
