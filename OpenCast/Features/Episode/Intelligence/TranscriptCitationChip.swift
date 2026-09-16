import SwiftUI

/// A tappable `m:ss` timestamp that seeks playback to the cited segment.
struct TranscriptCitationChip: View {
    let time: TimeInterval
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(time.formattedPlaybackDuration, systemImage: "play.fill")
                .font(.subheadline)
                .monospacedDigit()
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .accessibilityLabel("Play from \(time.formattedPlaybackDuration)")
    }
}
