import Intents

nonisolated enum SiriPlayMediaIntentFactory {
    static func make(
        mediaItems: [INMediaItem]? = nil,
        mediaContainer: INMediaItem? = nil,
        resumePlayback: Bool? = false,
        playbackSpeed: Double? = nil,
        mediaName: String? = nil,
        mediaType: INMediaItemType = .unknown
    ) -> INPlayMediaIntent {
        let mediaSearch = mediaName.map {
            INMediaSearch(
                mediaType: mediaType,
                sortOrder: .unknown,
                mediaName: $0,
                artistName: nil,
                albumName: nil,
                genreNames: nil,
                moodNames: nil,
                releaseDate: nil,
                reference: .unknown,
                mediaIdentifier: nil
            )
        }
        return INPlayMediaIntent(
            mediaItems: mediaItems,
            mediaContainer: mediaContainer,
            playShuffled: false,
            playbackRepeatMode: .none,
            resumePlayback: resumePlayback,
            playbackQueueLocation: .now,
            playbackSpeed: playbackSpeed,
            mediaSearch: mediaSearch
        )
    }

    static func mediaItem(
        identifier: String,
        title: String,
        type: INMediaItemType,
        artist: String? = nil
    ) -> INMediaItem {
        INMediaItem(
            identifier: identifier,
            title: title,
            type: type,
            artwork: nil,
            artist: artist
        )
    }
}
