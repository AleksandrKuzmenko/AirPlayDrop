import SwiftUI
import UniformTypeIdentifiers

struct DropZoneView: View {
    let onDrop: ([URL]) -> Void
    @State private var isTargeted = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                    style: StrokeStyle(lineWidth: 2, dash: [6, 3])
                )
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isTargeted ? Color.accentColor.opacity(0.07) : Color.clear)
                )

            VStack(spacing: 8) {
                Image(systemName: isTargeted ? "film.stack.fill" : "film.stack")
                    .font(.system(size: 28))
                    .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
                Text("Drop supported video files here")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .animation(.easeInOut(duration: 0.15), value: isTargeted)
        }
        .frame(height: 96)
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL], isTargeted: $isTargeted, perform: handleProviders)
    }

    private func handleProviders(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        var pending = providers.count
        var urls: [URL] = []
        let lock = NSLock()

        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                lock.lock()
                defer { lock.unlock() }
                if let url, url.isFileURL {
                    urls.append(url)
                }
                pending -= 1
                if pending == 0 {
                    let collected = urls
                    DispatchQueue.main.async {
                        if !collected.isEmpty { onDrop(collected) }
                    }
                }
            }
        }
        return true
    }
}
