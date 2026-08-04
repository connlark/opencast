#if DEBUG
import Foundation
import OpenCastCore
import SwiftData

enum AppStoreScreenshotSeedData {
    private static let artworkSubdirectory = "AppStoreScreenshots/Artwork"

    static func seed(in container: ModelContainer, cacheStore: SQLiteLocalLibraryCacheStore) throws {
        let context = ModelContext(container)
        let refreshedAt = Date(timeIntervalSince1970: 1_779_814_800)
        let audioURL = try AppStoreScreenshotSeedAudio.write().absoluteString

        for podcast in AppStoreScreenshotSeedCatalog.podcasts {
            let artworkURL = try artworkURL(named: podcast.artworkName).absoluteString
            context.insert(
                SubscriptionRecord(
                    feedURL: podcast.id,
                    title: podcast.title,
                    author: podcast.author,
                    artworkURL: artworkURL,
                    subscribedAt: refreshedAt.addingTimeInterval(-Double(podcast.title.count * 300)),
                    lastRefreshAt: refreshedAt
                )
            )
            try OpenCastUITestSeedData.upsertSeedFeed(
                into: cacheStore,
                feedURL: podcast.id,
                title: podcast.title,
                author: podcast.author,
                summary: podcast.summary,
                websiteURL: podcast.websiteURL,
                artworkURL: artworkURL,
                episodes: podcast.episodes.map { episode in
                    Episode(
                        id: EpisodeID(rawValue: episode.id),
                        podcastID: PodcastID(rawValue: podcast.id),
                        podcastTitle: podcast.title,
                        title: episode.title,
                        summary: episode.summary,
                        showNotesHTML: episode.showNotesHTML,
                        publishedAt: episode.publishedAt,
                        duration: episode.duration,
                        audioURL: URL(string: audioURL),
                        artworkURL: URL(string: artworkURL),
                        guid: episode.id
                    )
                },
                refreshedAt: refreshedAt
            )

            for episode in podcast.episodes {
                if let position = episode.position {
                    context.insert(
                        EpisodeProgressRecord(
                            episodeID: episode.id,
                            podcastID: podcast.id,
                            position: position,
                            duration: episode.duration,
                            isPlayed: episode.isPlayed,
                            updatedAt: refreshedAt
                        )
                    )
                }
            }
        }

        context.insert(LocalPreferenceRecord(
            key: PlaybackSettingsStore.voiceBoostModePreferenceKey,
            value: VoiceBoostMode.perEpisode.rawValue,
            updatedAt: refreshedAt
        ))

        try AppStoreScreenshotSeedTranscript.seed(
            in: context,
            audioURL: audioURL,
            createdAt: refreshedAt
        )

        try context.save()
    }

    private static func artworkURL(named name: String) throws -> URL {
        if let url = Bundle.main.url(
            forResource: name,
            withExtension: "png",
            subdirectory: artworkSubdirectory
        ) {
            return url
        }

        throw AppStoreScreenshotSeedArtworkError.missing(
            name: name,
            subdirectory: artworkSubdirectory
        )
    }
}
#endif
