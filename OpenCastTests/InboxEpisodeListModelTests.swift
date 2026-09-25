import Foundation
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Inbox episode list model")
struct InboxEpisodeListModelTests {
    @Test("All Episodes with Up Next shown passes the list through and reads nothing")
    func allPassthroughReadsNothing() {
        let library = LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory())
        let episodes = [makeEpisode(id: "newer", publishedAt: 20), makeEpisode(id: "older", publishedAt: 10)]

        // The call stays outside `#expect`, which evaluates every argument
        // itself to capture it for the failure message.
        let model = InboxEpisodeListModel.make(
            episodes: episodes,
            filter: .all,
            hidesQueuedEpisodes: false,
            library: library,
            downloadRecords: unreached("download records", fallback: []),
            queuedEpisodeIDs: unreached("queued episode IDs", fallback: []),
            playingEpisodeID: unreached("playing episode ID", fallback: nil)
        )

        #expect(model.episodes.map(\.id) == ["newer", "older"])
        #expect(model.totalEpisodeCount == 2)
        #expect(!model.isFilteredEmpty)
    }

    @Test("Every other filter derives membership from progress and completed downloads")
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

        // The three progress filters never read download records.
        let unplayedModel = makeModel(.unplayed, episodes, library, downloads: unreached("download records", fallback: []))
        let inProgressModel = makeModel(.inProgress, episodes, library, downloads: unreached("download records", fallback: []))
        let playedModel = makeModel(.played, episodes, library, downloads: unreached("download records", fallback: []))
        let downloadedModel = makeModel(.downloaded, episodes, library, downloads: [downloadRecord])

        #expect(unplayedModel.episodes.map(\.id) == ["newest", "in-progress", "downloaded"])
        #expect(inProgressModel.episodes.map(\.id) == ["in-progress"])
        #expect(playedModel.episodes.map(\.id) == ["played"])
        #expect(downloadedModel.episodes.map(\.id) == ["downloaded"])
        #expect(unplayedModel.totalEpisodeCount == 4)
    }

    @Test("Hiding Up Next drops queued rows under any filter except the playing episode")
    func hidesQueuedEpisodesExceptThePlayingOne() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let library = LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory())
        let playing = makeEpisode(id: "playing", publishedAt: 50)
        let queued = makeEpisode(id: "queued", publishedAt: 40)
        let queuedPlayed = makeEpisode(id: "queued-played", publishedAt: 30)
        let unqueued = makeEpisode(id: "unqueued", publishedAt: 20)
        let queuedDownloaded = makeEpisode(id: "queued-downloaded", publishedAt: 10)
        let episodes = [playing, queued, queuedPlayed, unqueued, queuedDownloaded]
        #expect(library.markEpisodePlayed(queuedPlayed, modelContext: context))
        let downloadRecord = EpisodeDownloadRecord(
            episodeID: queuedDownloaded.episodeID,
            podcastID: queuedDownloaded.podcastID,
            sourceAudioURL: queuedDownloaded.audioURL ?? "",
            state: .completed
        )
        // The playing episode still has a stale queue entry.
        let queuedIDs: Set<String> = ["playing", "queued", "queued-played", "queued-downloaded"]

        let allModel = makeModel(
            .all, episodes, library,
            hidesQueued: true, queued: queuedIDs, playing: "playing",
            downloads: unreached("download records", fallback: [])
        )
        let unplayedModel = makeModel(
            .unplayed, episodes, library,
            hidesQueued: true, queued: queuedIDs, playing: "playing",
            downloads: unreached("download records", fallback: [])
        )
        let downloadedModel = makeModel(
            .downloaded, episodes, library,
            hidesQueued: true, queued: queuedIDs, playing: nil,
            downloads: [downloadRecord]
        )

        #expect(allModel.episodes.map(\.id) == ["playing", "unqueued"])
        #expect(unplayedModel.episodes.map(\.id) == ["playing", "unqueued"])
        #expect(downloadedModel.episodes.isEmpty)
        #expect(downloadedModel.isFilteredEmpty)
    }

    @Test("Hiding Up Next with an empty queue changes nothing")
    func hideQueuedWithEmptyQueueIsNoOp() {
        let library = LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory())
        let episodes = [makeEpisode(id: "newer", publishedAt: 20), makeEpisode(id: "older", publishedAt: 10)]

        let model = makeModel(
            .all, episodes, library,
            hidesQueued: true, queued: [], playing: nil,
            downloads: unreached("download records", fallback: [])
        )

        #expect(model.episodes.map(\.id) == ["newer", "older"])
        #expect(!model.isFilteredEmpty)
    }

    @Test("Filtered empty distinguishes a nonempty inbox")
    func filteredEmptyState() {
        let library = LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory())

        let emptyInbox = makeModel(.downloaded, [], library, downloads: [])
        let filteredToNothing = makeModel(.downloaded, [makeEpisode(id: "episode", publishedAt: 10)], library, downloads: [])

        #expect(emptyInbox.episodes.isEmpty)
        #expect(!emptyInbox.isFilteredEmpty)
        #expect(filteredToNothing.episodes.isEmpty)
        #expect(filteredToNothing.totalEpisodeCount == 1)
        #expect(filteredToNothing.isFilteredEmpty)
    }

    private func makeModel(
        _ filter: PodcastEpisodeFilter,
        _ episodes: [EpisodeListItemSnapshot],
        _ library: LibraryStore,
        hidesQueued: Bool = false,
        queued: @autoclosure () -> Set<String> = [],
        playing: @autoclosure () -> String? = nil,
        downloads: @autoclosure () -> [EpisodeDownloadRecord]
    ) -> InboxEpisodeListModel {
        InboxEpisodeListModel.make(
            episodes: episodes,
            filter: filter,
            hidesQueuedEpisodes: hidesQueued,
            library: library,
            downloadRecords: downloads(),
            queuedEpisodeIDs: queued(),
            playingEpisodeID: playing()
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

    /// Stands in for an input the model must not read; reading it fails the test.
    private func unreached<Value>(_ input: String, fallback: Value) -> Value {
        Issue.record("\(input) was read")
        return fallback
    }
}
