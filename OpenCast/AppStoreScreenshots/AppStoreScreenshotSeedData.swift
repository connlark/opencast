#if DEBUG
import Foundation
import OpenCastCore
import OpenCastTranscription
import SwiftData

enum AppStoreScreenshotSeedData {
    private static let artworkSubdirectory = "AppStoreScreenshots/Artwork"

    static func seed(in container: ModelContainer, cacheStore: SQLiteLocalLibraryCacheStore) throws {
        let context = ModelContext(container)
        // A few hours back so library rows read "Refreshed 3 hours ago", not a
        // live seconds counter.
        let refreshedAt = AppStoreScreenshotSeedCatalog.referenceDate.addingTimeInterval(-3 * 3_600)
        let audioFileURL = try AppStoreScreenshotSeedAudio.write()
        let audioURL = audioFileURL.absoluteString

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

        // The transcript and skip zones only follow playback when the
        // transcript's source SHA matches a completed download of the file
        // being played, so the primary episode gets a real download record.
        let download = try seedCompletedDownload(
            in: context,
            audioFileURL: audioFileURL,
            createdAt: refreshedAt
        )
        let transcriptDocument = try AppStoreScreenshotSeedTranscript.seed(
            in: context,
            audioURL: audioURL,
            sourceFileSHA256: download.sourceFileSHA256,
            sourceFileByteCount: download.bytesReceived,
            createdAt: refreshedAt
        )
        try AppStoreScreenshotSeedChapters.seed(
            in: context,
            transcriptDocument: transcriptDocument,
            createdAt: refreshedAt
        )

        try context.save()
    }

    private static func seedCompletedDownload(
        in context: ModelContext,
        audioFileURL: URL,
        createdAt: Date
    ) throws -> EpisodeDownloadRecord {
        let episodeID = AppStoreScreenshotSeedCatalog.primaryEpisodeID
        let fileStore = EpisodeDownloadFileStore()
        let relativePath = fileStore.relativePath(episodeID: episodeID, sourceAudioURL: audioFileURL)
        let audioData = try Data(contentsOf: audioFileURL)
        try fileStore.prepareDownloadsDirectory()
        try audioData.write(to: fileStore.fileURL(relativePath: relativePath), options: .atomic)

        let download = EpisodeDownloadRecord(
            episodeID: episodeID,
            podcastID: AppStoreScreenshotSeedCatalog.primaryFeedURL,
            sourceAudioURL: audioFileURL.absoluteString,
            localRelativePath: relativePath,
            state: .completed,
            bytesReceived: Int64(audioData.count),
            bytesExpected: Int64(audioData.count),
            episodeTitle: AppStoreScreenshotSeedCatalog.primaryEpisodeTitle,
            podcastTitle: AppStoreScreenshotSeedCatalog.primaryPodcastTitle,
            duration: AppStoreScreenshotSeedCatalog.primaryEpisodeDuration,
            createdAt: createdAt,
            updatedAt: createdAt
        )
        download.sourceFileSHA256 = OpenCastSHA256.hash(audioData)
        context.insert(download)
        return download
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
