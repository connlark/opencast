import SwiftUI

struct NowPlayingProgressView: View {
    let duration: TimeInterval?
    let displayedPosition: TimeInterval
    @Binding var scrubPosition: TimeInterval
    let onEditingChanged: (Bool) -> Void

    var body: some View {
        VStack(spacing: 6) {
            Slider(
                value: $scrubPosition,
                in: 0...sliderUpperBound,
                onEditingChanged: onEditingChanged
            )
            .accessibilityLabel("Playback Progress")
            .accessibilityIdentifier("Playback Progress")
            .accessibilityValue(progressAccessibilityValue)

            HStack {
                Text(displayedPosition.formattedPlaybackDuration)
                    .monospacedDigit()
                Spacer()
                Text(remainingDurationText)
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .onChange(of: sliderUpperBound) { _, upperBound in
            scrubPosition = scrubPosition.clamped(to: 0...upperBound)
        }
    }

    private var sliderUpperBound: TimeInterval {
        max(duration ?? max(displayedPosition, 1), 1)
    }

    private var remainingDurationText: String {
        guard let duration, duration.isFinite, duration > 0 else {
            return "--:--"
        }

        let remaining = max(duration - displayedPosition, 0)
        return "-\(remaining.formattedPlaybackDuration)"
    }

    private var progressAccessibilityValue: String {
        guard let duration, duration.isFinite, duration > 0 else {
            return "\(displayedPosition.formattedPlaybackDuration) elapsed"
        }

        return "\(displayedPosition.formattedPlaybackDuration) elapsed, \(remainingDurationText) remaining"
    }
}
