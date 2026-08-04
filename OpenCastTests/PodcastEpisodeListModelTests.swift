import Foundation
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Podcast episode list model")
struct PodcastEpisodeListModelTests {
    @Test("Every filter derives membership from progress and completed downloads")
    func filterMembership() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let library = LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory())
        let newest = makeEpisode(id: "newest", publishedAt: 40)
        let inProgress = makeEpisode(id: "in-progress", publishedAt: 30)
        let played = makeEpisode(id: "played", publishedAt: 20)
        let downloaded = makeEpisode(id: "downloaded", publishedAt: 10)
        let episodes = [newest, inProgress, played, downloaded]

        #expect(
            library.updateProgress(
                episodeID: inProgress.episodeID,
                podcastID: inProgress.podcastID,
                position: 20,
                duration: 100,
                modelContext: context
            )
        )
        #expect(library.markEpisodePlayed(played, modelContext: context))
        let downloadRecord = EpisodeDownloadRecord(
            episodeID: downloaded.episodeID,
            podcastID: downloaded.podcastID,
            sourceAudioURL: downloaded.audioURL ?? "",
            state: .completed
        )

        #expect(makeModel(.all, episodes, library, [downloadRecord]).episodes.map(\.id) == episodes.map(\.id))
        #expect(
            makeModel(.unplayed, episodes, library, [downloadRecord]).episodes.map(\.id)
                == ["newest", "in-progress", "downloaded"]
        )
        #expect(makeModel(.inProgress, episodes, library, [downloadRecord]).episodes.map(\.id) == ["in-progress"])
        #expect(makeModel(.played, episodes, library, [downloadRecord]).episodes.map(\.id) == ["played"])
        #expect(makeModel(.downloaded, episodes, library, [downloadRecord]).episodes.map(\.id) == ["downloaded"])
    }

    @Test("Filtering composes with sorting and owns the animation key")
    func filterAndSortComposition() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let library = LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory())
        let newest = makeEpisode(id: "newest", publishedAt: 30)
        let middle = makeEpisode(id: "middle", publishedAt: 20)
        let oldest = makeEpisode(id: "oldest", publishedAt: 10)
        #expect(library.markEpisodePlayed(middle, modelContext: context))

        let model = PodcastEpisodeListModel.make(
            episodes: [newest, middle, oldest],
            filter: .unplayed,
            sortOrder: .oldestFirst,
            library: library,
            downloadRecords: []
        )

        #expect(model.episodes.map(\.id) == ["oldest", "newest"])
        #expect(model.animationKey == ["oldest", "newest"])
        #expect(model.totalEpisodeCount == 3)
        #expect(!model.isFilteredEmpty)
    }

    @Test("Filtered empty distinguishes a nonempty feed")
    func filteredEmptyState() {
        let library = LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory())
        let model = PodcastEpisodeListModel.make(
            episodes: [makeEpisode(id: "episode", publishedAt: 10)],
            filter: .downloaded,
            sortOrder: .newestFirst,
            library: library,
            downloadRecords: []
        )

        #expect(model.episodes.isEmpty)
        #expect(model.totalEpisodeCount == 1)
        #expect(model.animationKey.isEmpty)
        #expect(model.isFilteredEmpty)
    }

    @Test("Newest first preserves the cache's existing order")
    func newestFirstPassthrough() {
        let library = LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory())
        let older = makeEpisode(id: "older", publishedAt: 10)
        let newer = makeEpisode(id: "newer", publishedAt: 20)

        let model = PodcastEpisodeListModel.make(
            episodes: [older, newer],
            filter: .all,
            sortOrder: .newestFirst,
            library: library,
            downloadRecords: []
        )

        #expect(model.episodes.map(\.id) == ["older", "newer"])
    }

    private func makeModel(
        _ filter: PodcastEpisodeFilter,
        _ episodes: [EpisodeListItemSnapshot],
        _ library: LibraryStore,
        _ downloads: [EpisodeDownloadRecord]
    ) -> PodcastEpisodeListModel {
        PodcastEpisodeListModel.make(
            episodes: episodes,
            filter: filter,
            sortOrder: .newestFirst,
            library: library,
            downloadRecords: downloads
        )
    }

    private func makeEpisode(id: String, publishedAt: TimeInterval) -> EpisodeListItemSnapshot {
        .fixture(
            episodeID: id,
            podcastTitle: "Podcast",
            title: "Episode \(id)",
            publishedAt: Date(timeIntervalSince1970: publishedAt),
            duration: 100,
            audioURL: "https://example.com/\(id).mp3",
            guid: id
        )
    }
}
