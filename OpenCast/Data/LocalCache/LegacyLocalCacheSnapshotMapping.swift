import Foundation

extension PodcastCacheSnapshot {
    @MainActor
    init(legacyRecord record: PodcastCacheRecord) {
        self.init(
            feedURL: record.feedURL,
            title: record.title,
            author: record.author,
            summary: record.summary,
            websiteURL: record.websiteURL,
            artworkURL: record.artworkURL,
            artworkPreview: record.artworkPreview,
            updatedAt: record.updatedAt
        )
    }
}

extension EpisodeDetailSnapshot {
    @MainActor
    init(legacyRecord record: EpisodeCacheRecord) {
        self.init(
            listItem: EpisodeListItemSnapshot(
                episodeID: record.episodeID,
                podcastID: record.podcastID,
                podcastTitle: record.podcastTitle,
                title: record.title,
                summary: record.summary,
                publishedAt: record.publishedAt,
                duration: record.duration,
                audioURL: record.audioURL,
                artworkURL: record.artworkURL,
                artworkPreview: record.artworkPreview,
                guid: record.guid,
                cachedAt: record.cachedAt
            ),
            showNotesHTML: record.showNotesHTML
        )
    }
}

extension RefreshLogSnapshot {
    @MainActor
    init(legacyRecord record: RefreshLogRecord) {
        self.init(
            refreshID: record.refreshID,
            feedURL: record.feedURL,
            startedAt: record.startedAt,
            finishedAt: record.finishedAt,
            errorMessage: record.errorMessage
        )
    }
}
