import Foundation
import OpenCastCore
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Downloads list model")
struct DownloadsListModelTests {
    @Test("Partitions every download state and owns section sort order")
    func partitionsAndSortsRecords() {
        let library = LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory())
        let paused = makeRecord(
            id: "paused",
            state: .paused,
            createdAt: date(10),
            updatedAt: date(10)
        )
        let downloading = makeRecord(
            id: "downloading",
            state: .downloading,
            createdAt: date(20),
            updatedAt: date(20)
        )
        let failed = makeRecord(id: "failed", state: .failed, updatedAt: date(30))
        let missing = makeRecord(id: "missing", state: .missing, updatedAt: date(40))
        let unknown = makeRecord(id: "unknown", state: .failed, updatedAt: date(50))
        unknown.stateRawValue = "future-state"
        let olderDownload = makeRecord(id: "older", state: .completed, updatedAt: date(60))
        let newerDownload = makeRecord(id: "newer", state: .completed, updatedAt: date(70))

        let model = DownloadsListModel.make(
            records: [failed, newerDownload, downloading, olderDownload, unknown, paused, missing],
            library: library
        )

        #expect(model.downloading.map(\.id) == ["paused", "downloading"])
        #expect(model.failed.map(\.id) == ["unknown", "missing", "failed"])
        #expect(model.downloaded.map(\.id) == ["newer", "older"])
        #expect(model.animationKey.downloadingEpisodeIDs == ["paused", "downloading"])
        #expect(model.animationKey.stateRawValuesByEpisodeID["unknown"] == "future-state")
        #expect(model.isEmpty == false)
    }

    @Test("Unplayed filter applies only to completed downloads")
    func filtersPlayedCompletedDownloads() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let library = LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory())
        let played = makeRecord(id: "played", state: .completed, updatedAt: date(20))
        let unplayed = makeRecord(id: "unplayed", state: .completed, updatedAt: date(10))
        let failed = makeRecord(id: "failed", state: .failed, updatedAt: date(30))
        let playedEpisode = DownloadListItem.make(record: played, library: library).episode

        #expect(library.markEpisodePlayed(playedEpisode, modelContext: context))

        let allDownloads = DownloadsListModel.make(
            records: [played, unplayed, failed],
            library: library
        )
        let model = allDownloads.filteringUnplayed(using: library)

        #expect(model.downloaded.map(\.id) == ["unplayed"])
        #expect(model.failed.map(\.id) == ["failed"])
        #expect(allDownloads.downloaded.map(\.id) == ["played", "unplayed"])
    }

    @Test("Orphan fallback preserves metadata and humanizes a missing title")
    func synthesizesOrphanFallback() {
        let library = LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory())
        let metadataRecord = EpisodeDownloadRecord(
            episodeID: "metadata",
            podcastID: "https://example.com/removed.xml",
            sourceAudioURL: "https://cdn.example.com/metadata.mp3",
            state: .completed,
            episodeTitle: "Saved Episode",
            podcastTitle: "Saved Podcast",
            artworkURLString: "https://example.com/art.jpg",
            duration: 321,
            publishedAt: date(100),
            updatedAt: date(200)
        )
        let sparseRecord = EpisodeDownloadRecord(
            episodeID: "sparse",
            podcastID: "https://example.com/removed.xml",
            sourceAudioURL: "https://cdn.example.com/the-great_episode.mp3",
            state: .completed
        )

        let metadataItem = DownloadListItem.make(record: metadataRecord, library: library)
        let sparseItem = DownloadListItem.make(record: sparseRecord, library: library)

        #expect(metadataItem.isOrphaned)
        #expect(metadataItem.episode.title == "Saved Episode")
        #expect(metadataItem.episode.podcastTitle == "Saved Podcast")
        #expect(metadataItem.episode.artworkURL == "https://example.com/art.jpg")
        #expect(metadataItem.episode.duration == 321)
        #expect(metadataItem.episode.publishedAt == date(100))
        #expect(sparseItem.isOrphaned)
        #expect(sparseItem.episode.title == "The Great Episode")
        #expect(sparseItem.episode.podcastTitle == "Removed Podcast")
    }

    private func makeRecord(
        id: String,
        state: EpisodeDownloadState,
        createdAt: Date = Date(timeIntervalSince1970: 0),
        updatedAt: Date
    ) -> EpisodeDownloadRecord {
        EpisodeDownloadRecord(
            episodeID: id,
            podcastID: "https://example.com/feed.xml",
            sourceAudioURL: "https://example.com/\(id).mp3",
            state: state,
            episodeTitle: "Episode \(id)",
            podcastTitle: "Podcast",
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }
}
