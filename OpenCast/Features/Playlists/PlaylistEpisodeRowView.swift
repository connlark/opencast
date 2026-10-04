import SwiftData
import SwiftUI

/// A playlist episode that still resolves: the Inbox row, played from here
/// by a tap, or by its play button with Tap to Play off (the rest of the
/// playlist goes to the front of Up Next), with the shared episode context
/// menu. A manual playlist's row carries its item ID and plays that exact
/// row; a smart playlist's row has none and plays by episode.
struct PlaylistEpisodeRowView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @State private var playFeedback = 0

    let itemID: String?
    let playlistID: String
    let episode: EpisodeListItemSnapshot
    let onOpenEpisode: (String) -> Void

    static func accessibilityIdentifier(for itemID: String) -> String {
        "playlist-item-\(itemID)"
    }

    static func accessibilityIdentifier(forEpisodeID episodeID: String) -> String {
        "playlist-episode-\(episodeID)"
    }

    var body: some View {
        Button(action: primaryAction) {
            EpisodeRowView(episode: episode, onPlay: playButtonAction)
        }
        .buttonStyle(.plain)
        .modifier(
            EpisodeRowContextMenuModifier(
                episode: episode,
                showsGoToShow: true,
                onViewDetails: viewEpisodeDetails
            )
        )
        .sensoryFeedback(.impact(flexibility: .soft), trigger: playFeedback)
        .accessibilityIdentifier(rowAccessibilityIdentifier)
    }

    private var rowAccessibilityIdentifier: String {
        if let itemID {
            Self.accessibilityIdentifier(for: itemID)
        } else {
            Self.accessibilityIdentifier(forEpisodeID: episode.episodeID)
        }
    }

    /// With Tap to Play off the row opens the episode, so the trailing glyph
    /// becomes the play button.
    private var playButtonAction: (() -> Void)? {
        guard !appModel.playbackSettings.isTapToPlayEnabled else {
            return nil
        }
        return play
    }

    private func primaryAction() {
        if appModel.playbackSettings.isTapToPlayEnabled {
            play()
        } else {
            viewEpisodeDetails(episode)
        }
    }

    private func play() {
        nowPlayingProbeMark("playepisode-tap")
        // The app model reports a failed start or an unresolvable episode itself.
        let didStart = if let itemID {
            appModel.playPlaylistItem(itemID, in: playlistID, modelContext: modelContext)
        } else {
            appModel.playPlaylistEpisode(episode.episodeID, in: playlistID, modelContext: modelContext)
        }
        guard didStart else {
            return
        }
        playFeedback += 1
    }

    private func viewEpisodeDetails(_ episode: EpisodeListItemSnapshot) {
        onOpenEpisode(episode.episodeID)
    }
}
