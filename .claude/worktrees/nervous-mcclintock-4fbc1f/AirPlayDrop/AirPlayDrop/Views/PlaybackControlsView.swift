import SwiftUI

struct PlaybackControlsView: View {
    let store: PlaylistStore
    let controller: PlaybackController

    private var canPlay: Bool {
        guard let item = store.selectedItem else { return false }
        return item.state == .ready && !controller.isPlaying
    }

    private var canStop: Bool { controller.isPlaying }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                controller.play()
            } label: {
                Label("Play", systemImage: "play.fill")
            }
            .disabled(!canPlay)
            .keyboardShortcut(.space, modifiers: [])

            Button {
                controller.stop()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .disabled(!canStop)

            Spacer()

            RoutePickerRepresentable()
                .frame(width: 28, height: 28)
                .help("AirPlay / Output device")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
