import SwiftUI

/// The wide mini player's scrubber: the current episode's position on a
/// slider, seeking through the same playback call the card's progress
/// section makes, on release only.
struct MiniPlayerScrubber: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase

    @State private var track = Track()
    @State private var scrubFeedback = 0

    var body: some View {
        Slider(value: $track.position, in: 0...track.upperBound, onEditingChanged: updateScrubbing)
            // Not the card's "Playback Progress": the accessory stays in the
            // accessibility tree under the presented card, and a label query
            // for the card's slider must not find this one too.
            .accessibilityLabel("Playback Position")
            .accessibilityValue("\(track.position.formattedPlaybackDuration) elapsed")
            .accessibilityIdentifier("mini-player-scrubber")
            .sensoryFeedback(.selection, trigger: scrubFeedback)
            .onChange(of: appModel.playback.duration, initial: true) { _, duration in
                track.duration = duration
            }
            .onChange(of: observedPosition, initial: true) { _, position in
                if let position {
                    track.follow(position)
                }
            }
            .onChange(of: currentEpisodeID) { _, _ in
                track.replaceEpisode(position: appModel.playback.position, duration: appModel.playback.duration)
            }
    }

    private var currentEpisodeID: String? {
        appModel.playback.currentEpisode?.id.rawValue
    }

    /// The playback clock, read only while the accessory is on screen: not
    /// behind the presented card, and not while the scene is in the
    /// background.
    private var observedPosition: TimeInterval? {
        !appModel.isNowPlayingPresented && scenePhase == .active ? appModel.playback.position : nil
    }

    private func updateScrubbing(_ editing: Bool) {
        if editing {
            track.beginDrag(episodeID: currentEpisodeID)
            scrubFeedback += 1
        } else if let seekPosition = track.endDrag(currentEpisodeID: currentEpisodeID) {
            appModel.playback.seek(to: seekPosition)
        }
    }

    /// The scrubber's state: the slider's position in seconds and the drag in
    /// progress. A drag seeks once, on release, and only the episode it
    /// started on.
    nonisolated struct Track: Equatable, Sendable {
        var position: TimeInterval = 0
        /// The playing episode's duration, when known. A change rescales the
        /// track under the position, which keeps its seconds inside the new
        /// range.
        var duration: TimeInterval? {
            didSet {
                position = position.clamped(to: 0...upperBound)
            }
        }

        private(set) var isDragging = false
        private var dragEpisodeID: String?

        /// The card's range rule: the duration, or the position while the
        /// duration is unknown, and never less than one second.
        var upperBound: TimeInterval {
            max(duration ?? max(position, 1), 1)
        }

        var fraction: Double {
            position / upperBound
        }

        mutating func follow(_ playbackPosition: TimeInterval) {
            guard !isDragging else {
                return
            }
            position = playbackPosition
        }

        mutating func beginDrag(episodeID: String?) {
            isDragging = true
            dragEpisodeID = episodeID
        }

        /// The drag ended: the position to seek to, or nil when no drag was in
        /// progress or the episode changed since it began.
        mutating func endDrag(currentEpisodeID: String?) -> TimeInterval? {
            guard isDragging else {
                return nil
            }
            isDragging = false
            guard let dragEpisodeID, dragEpisodeID == currentEpisodeID else {
                return nil
            }
            return position
        }

        /// Another episode took over: a drag in progress ends without a seek
        /// (its position was chosen on the old episode's timeline), and the
        /// track takes the new episode's position and duration.
        mutating func replaceEpisode(position: TimeInterval, duration: TimeInterval?) {
            isDragging = false
            dragEpisodeID = nil
            self.duration = duration
            self.position = position
        }
    }
}
