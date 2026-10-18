import OpenCastPlayback
import SwiftUI

struct NowPlayingProgressView: View {
    let duration: TimeInterval?
    let displayedPosition: TimeInterval
    let zones: [PlaybackSkipZone]
    var displayOnlyZones: [PlaybackSkipZone] = []
    /// Chapter start times marked on the rail under the slider. They stay
    /// off the slider itself: the stock tick initializer turns the control
    /// into a discrete slider that snaps to its ticks, which breaks scrubbing.
    var chapterBoundaries: [TimeInterval] = []
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

            if !zones.isEmpty || !displayOnlyZones.isEmpty || !chapterMarkers.isEmpty {
                NowPlayingSkipZoneRail(
                    duration: sliderUpperBound,
                    zones: zones,
                    displayOnlyZones: displayOnlyZones,
                    chapterMarkers: chapterMarkers
                )
            }

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

    /// Markers only make sense against a known duration; one at or past the
    /// end of the track is dropped rather than drawn on the edge.
    private var chapterMarkers: [TimeInterval] {
        guard let duration, duration.isFinite, duration > 0 else {
            return []
        }
        return chapterBoundaries.filter { $0 > 0 && $0 < duration }
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
