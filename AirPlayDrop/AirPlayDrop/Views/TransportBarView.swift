import SwiftUI

struct TransportBarView: View {
    @Bindable var controller: PlaybackController

    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0
    @State private var volume: Double = 1.0

    private var seekable: Bool { controller.duration > 0 }

    var body: some View {
        VStack(spacing: 2) {
            if isScrubbing, let image = controller.scrubPreview {
                Image(decorative: image, scale: 1, orientation: .up)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 240, maxHeight: 135)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(alignment: .bottom) {
                        Text(format(scrubValue))
                            .font(.caption.monospacedDigit())
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.7), in: Capsule())
                            .foregroundStyle(.white)
                            .padding(4)
                    }
                    .accessibilityHidden(true)
            }
            Slider(
                value: Binding(
                    get: { isScrubbing ? scrubValue : controller.currentTime },
                    set: {
                        scrubValue = $0
                        if isScrubbing { controller.requestThumbnail(at: $0) }
                    }
                ),
                in: 0...max(controller.duration, 0.01),
                onEditingChanged: { editing in
                    if editing {
                        scrubValue = controller.currentTime
                        isScrubbing = true
                        controller.requestThumbnail(at: scrubValue)
                    } else {
                        controller.seek(to: scrubValue)
                        isScrubbing = false
                        controller.clearThumbnail()
                    }
                }
            )
            .disabled(!seekable)

            HStack(spacing: 10) {
                if controller.hasResumableProgress {
                    Button("Start Over") { controller.startOver() }
                        .buttonStyle(.borderless)
                        .help("Start this video from the beginning")
                        .accessibilityLabel("Start Over")
                }
                Text(format(isScrubbing ? scrubValue : controller.currentTime))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 60, alignment: .leading)

                Spacer()

                HStack(spacing: 4) {
                    Image(systemName: volumeIcon)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                    Slider(value: $volume, in: 0...1) { _ in
                        controller.volume = Float(volume)
                    }
                    .frame(width: 90)
                }

                Spacer()

                Text("-" + format(max(controller.duration - (isScrubbing ? scrubValue : controller.currentTime), 0)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 60, alignment: .trailing)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.bar)
        .onAppear { volume = Double(controller.volume) }
    }

    private var volumeIcon: String {
        switch volume {
        case 0:         return "speaker.slash.fill"
        case ..<0.33:   return "speaker.wave.1.fill"
        case ..<0.66:   return "speaker.wave.2.fill"
        default:        return "speaker.wave.3.fill"
        }
    }

    private func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "–:––" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
