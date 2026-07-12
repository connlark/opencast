import SwiftUI

struct TranscriptResumePill: View {
    @Environment(OpenCastAppModel.self) private var appModel

    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label {
                Text(position.formattedPlaybackDuration)
                    .monospacedDigit()
            } icon: {
                Image(systemName: "play.fill")
            }
            .font(.subheadline)
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityLabel("Resume following playback at \(position.formattedPlaybackDuration)")
    }

    /// Read here rather than passed in so the 1 Hz position tick only
    /// re-evaluates this pill, not the whole transcript screen.
    private var position: TimeInterval {
        appModel.playback.position
    }
}
