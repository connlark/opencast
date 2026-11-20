import OpenCastPlayback
import SwiftUI

struct NowPlayingProgressView: View {
    let duration: TimeInterval?
    let displayedPosition: TimeInterval
    let zones: [PlaybackSkipZone]
    var displayOnlyZones: [PlaybackSkipZone] = []
    /// Drawn on a rail under the slider: the stock tick initializer makes the slider discrete
    /// and snap to its ticks, which breaks scrubbing.
    var chapterBoundaries: [TimeInterval] = []
    var noteTimestamps: [TimeInterval] = []
    @Binding var scrubPosition: TimeInterval
    let onEditingChanged: (Bool) -> Void

    var body: some View {
        VStack(spacing: 6) {
            Slider(
                value: $scrubPosition,
                in: 0...sliderUpperBound,
                onEditingChanged: onEditingChanged
            )
            .accessibilityHint(noteTimestamps.isEmpty ? "" : "Notes marked at " + noteTimestamps.sorted().map { $0.formattedPlaybackDuration }.joined(separator: ", "))
            .accessibilityLabel("Playback Progress")
            .accessibilityIdentifier("Playback Progress")
            .accessibilityValue(progressAccessibilityValue)

            let noteMarkers = Self.noteMarkers(duration: duration, timestamps: noteTimestamps)
            if !zones.isEmpty || !displayOnlyZones.isEmpty || !chapterMarkers.isEmpty || !noteMarkers.isEmpty {
                NowPlayingSkipZoneRail(
                    duration: sliderUpperBound,
                    zones: zones,
                    displayOnlyZones: displayOnlyZones,
                    chapterMarkers: chapterMarkers,
                    noteMarkers: noteMarkers
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

    private var chapterMarkers: [TimeInterval] {
        guard let duration, duration.isFinite, duration > 0 else {
            return []
        }
        return chapterBoundaries.filter { $0 > 0 && $0 < duration }
    }

    static func noteMarkers(duration: TimeInterval?, timestamps: [TimeInterval]) -> [TimeInterval] {
        guard let duration, duration.isFinite, duration > 0 else {
            return []
        }
        return timestamps.filter { $0.isFinite && $0 >= 0 && $0 <= duration }
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
