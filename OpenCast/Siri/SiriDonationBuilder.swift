import Intents

nonisolated enum SiriDonationBuilder {
    static func interaction(for episode: EpisodeListItemSnapshot) -> INInteraction {
        let show = INMediaItem(
            identifier: episode.podcastID,
            title: episode.podcastTitle,
            type: .podcastShow,
            artwork: nil,
            artist: nil
        )
        let intent = INPlayMediaIntent(
            mediaItems: nil,
            mediaContainer: show,
            playShuffled: false,
            playbackRepeatMode: .none,
            resumePlayback: nil,
            playbackQueueLocation: .now,
            playbackSpeed: nil,
            mediaSearch: nil
        )
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.groupIdentifier = episode.podcastID
        return interaction
    }
}
