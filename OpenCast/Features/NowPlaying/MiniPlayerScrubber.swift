import SwiftUI

struct MiniPlayerScrubber: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase

    @State private var track = Track()
    @State private var scrubFeedback = 0

    var body: some View {
        Slider(value: $track.position, in: 0...track.upperBound, onEditingChanged: updateScrubbing)
            // Not the card's "Playback Progress": the accessory stays in the
            // accessibility tree under the presented card.
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

    nonisolated struct Track: Equatable, Sendable {
        var position: TimeInterval = 0
        var duration: TimeInterval? {
            didSet {
                position = position.clamped(to: 0...upperBound)
            }
        }

        private(set) var isDragging = false
        private var dragEpisodeID: String?

        var upperBound: TimeInterval {
            max(duration ?? max(position, 1), 1)
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

        mutating func replaceEpisode(position: TimeInterval, duration: TimeInterval?) {
            isDragging = false
            dragEpisodeID = nil
            self.duration = duration
            self.position = position
        }
    }
}
