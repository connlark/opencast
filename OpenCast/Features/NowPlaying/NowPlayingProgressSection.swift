import SwiftUI

/// Owns every body-level playback-position read on Now Playing — the 1 Hz
/// tick re-evaluates only this section, keeping the parent (and its open "…"
/// menu) stable while time advances.
struct NowPlayingProgressSection: View {
    @Environment(OpenCastAppModel.self) private var appModel

    @State private var scrubPosition: TimeInterval = 0
    @State private var isScrubbing = false
    @State private var scrubFeedback = 0
    @State private var scrubbingEpisodeID: String?

    var body: some View {
        NowPlayingProgressView(
            duration: appModel.playback.duration,
            displayedPosition: displayedPosition,
            zones: appModel.playback.skipZones,
            displayOnlyZones: appModel.displayOnlySkipZones,
            scrubPosition: $scrubPosition,
            onEditingChanged: updateScrubbing
        )
        .sensoryFeedback(.selection, trigger: scrubFeedback)
        .onAppear {
            scrubPosition = appModel.playback.position
        }
        .onChange(of: appModel.playback.position) { _, newPosition in
            guard !isScrubbing else {
                return
            }
            scrubPosition = newPosition
        }
        .onChange(of: currentEpisodeID) { _, _ in
            isScrubbing = false
            scrubPosition = appModel.playback.position
        }
    }

    private var currentEpisodeID: String? {
        appModel.playback.currentEpisode?.id.rawValue
    }

    private var displayedPosition: TimeInterval {
        isScrubbing ? scrubPosition : appModel.playback.position
    }

    private func updateScrubbing(_ editing: Bool) {
        if editing {
            scrubbingEpisodeID = currentEpisodeID
            isScrubbing = true
            scrubFeedback += 1
        } else {
            // A release after the episode changed mid-drag must not seek the new
            // episode to a position chosen on the old episode's timeline.
            guard scrubbingEpisodeID == currentEpisodeID else {
                isScrubbing = false
                scrubPosition = appModel.playback.position
                return
            }

            let seekPosition = scrubPosition
            isScrubbing = false
            appModel.playback.seek(to: seekPosition)
        }
    }
}
