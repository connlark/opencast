import Foundation
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Inbox episode list model")
struct InboxEpisodeListModelTests {
    @Test("The Inbox view under All with nothing archived and Up Next shown passes the list through and reads only the archived set")
    func allPassthroughReadsOnlyTheArchivedSet() {
        let library = LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory())
        let episodes = [makeEpisode(id: "newer", publishedAt: 20), makeEpisode(id: "older", publishedAt: 10)]

        // The call stays outside `#expect`, which evaluates every argument
        // itself to capture it for the failure message.
        let model = makeAllModel(episodes, library, archived: [])
        let archivedOutsideTheInbox = makeAllModel(episodes, library, archived: ["unfollowed-show-episode"])

        #expect(model.episodes.map(\.id) == ["newer", "older"])
        #expect(model.totalEpisodeCount == 2)
        #expect(!model.isFilteredEmpty)
        #expect(archivedOutsideTheInbox.episodes.map(\.id) == ["newer", "older"])
    }

    /// Both views read the archived set under All with Up Next shown, and
    /// nothing else: the Inbox lists what is not in it, the archive what is.
    @Test("All Episodes reads the archived set and nothing else in both views, paging included")
    func allReadsOnlyTheArchivedSetInBothViews() {
        let library = LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory())
        let episodes = [
            makeEpisode(id: "newest", publishedAt: 30),
            makeEpisode(id: "middle", publishedAt: 20),
            makeEpisode(id: "oldest", publishedAt: 10)
        ]

        let model = makeAllModel(episodes, library, archived: ["middle"])
        let paged = makeAllModel(episodes, library, archived: ["newest"], visibleEpisodeCount: 1)
        let nothingArchived = makeAllModel(episodes, library, archived: [], visibleEpisodeCount: 2)
        let archive = makeAllModel(episodes, library, showsArchived: true, archived: ["middle"])
        let pagedArchive = makeAllModel(
            episodes, library, showsArchived: true, archived: ["newest", "oldest"], visibleEpisodeCount: 1
        )
        let lastArchivedPage = makeAllModel(
            episodes, library, showsArchived: true, archived: ["newest", "oldest"], visibleEpisodeCount: 2
        )
        let emptyArchive = makeAllModel(episodes, library, showsArchived: true, archived: [])
        let emptyPagedArchive = makeAllModel(episodes, library, showsArchived: true, archived: [], visibleEpisodeCount: 1)

        #expect(model.episodes.map(\.id) == ["newest", "oldest"])
        #expect(model.totalEpisodeCount == 3)
        #expect(!model.hasMore)
        #expect(paged.episodes.map(\.id) == ["middle"])
        #expect(paged.hasMore)
        #expect(paged.totalEpisodeCount == 3)
        #expect(nothingArchived.episodes.map(\.id) == ["newest", "middle"])
        #expect(nothingArchived.hasMore)

        #expect(archive.episodes.map(\.id) == ["middle"])
        #expect(archive.totalEpisodeCount == 3)
        #expect(!archive.hasMore)
        #expect(pagedArchive.episodes.map(\.id) == ["newest"])
        #expect(pagedArchive.hasMore)
        #expect(!pagedArchive.isFilteredEmpty)
        #expect(lastArchivedPage.episodes.map(\.id) == ["newest", "oldest"])
        #expect(!lastArchivedPage.hasMore)
        #expect(emptyArchive.episodes.isEmpty)
        #expect(emptyArchive.totalEpisodeCount == 3)
        #expect(emptyArchive.isFilteredEmpty)
        #expect(emptyPagedArchive.episodes.isEmpty)
        #expect(!emptyPagedArchive.hasMore)
        #expect(emptyPagedArchive.isFilteredEmpty)
    }

    /// Each filter's archived twin sits beside an unarchived row the filter
    /// keeps, and in both views each such row follows a queued or playing
    /// twin under the same filter. A view that let the other view's rows
    /// through, a filter that dropped its own, or a view and filter that
    /// ignored Hide Up Next, before or after paging, lists the wrong rows.
    @Test("Under every filter and both Hide Up Next states the Inbox lists only unarchived episodes and the archive only archived ones, paging and groups included")
    func archivedEpisodesLeaveEveryFilter() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let library = LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory())
        let queuedUnheard = makeEpisode(id: "queued-unheard", publishedAt: 85)
        let newest = makeEpisode(id: "newest", publishedAt: 80)
        let archivedPlaying = makeEpisode(id: "archived-playing", publishedAt: 75)
        let archivedUnheard = makeEpisode(id: "archived-unheard", publishedAt: 70)
        let archivedQueuedInProgress = makeEpisode(id: "archived-queued-in-progress", publishedAt: 65)
        let archivedInProgress = makeEpisode(id: "archived-in-progress", publishedAt: 60)
        let queuedInProgress = makeEpisode(id: "queued-in-progress", publishedAt: 55)
        let inProgress = makeEpisode(id: "in-progress", publishedAt: 50)
        let archivedQueuedPlayed = makeEpisode(id: "archived-queued-played", publishedAt: 45)
        let archivedPlayed = makeEpisode(id: "archived-played", publishedAt: 40)
        let queuedPlayed = makeEpisode(id: "queued-played", publishedAt: 35)
        let played = makeEpisode(id: "played", publishedAt: 30)
        let archivedQueuedDownloaded = makeEpisode(id: "archived-queued-downloaded", publishedAt: 25)
        let archivedDownloaded = makeEpisode(id: "archived-downloaded", publishedAt: 20)
        let queuedDownloaded = makeEpisode(id: "queued-downloaded", publishedAt: 15)
        let downloaded = makeEpisode(id: "downloaded", publishedAt: 10)
        let episodes = [
            queuedUnheard, newest, archivedPlaying, archivedUnheard,
            archivedQueuedInProgress, archivedInProgress, queuedInProgress, inProgress,
            archivedQueuedPlayed, archivedPlayed, queuedPlayed, played,
            archivedQueuedDownloaded, archivedDownloaded, queuedDownloaded, downloaded
        ]
        for episode in [archivedQueuedInProgress, archivedInProgress, queuedInProgress, inProgress] {
            #expect(library.updateProgress(
                episodeID: episode.episodeID,
                podcastID: episode.podcastID,
                position: 20,
                duration: 100,
                modelContext: context
            ))
        }
        for episode in [archivedQueuedPlayed, archivedPlayed, queuedPlayed, played] {
            #expect(library.markEpisodePlayed(episode, modelContext: context))
        }
        #expect(library.archive(
            [
                archivedPlaying, archivedUnheard, archivedQueuedInProgress, archivedInProgress,
                archivedQueuedPlayed, archivedPlayed, archivedQueuedDownloaded, archivedDownloaded
            ],
            modelContext: context
        ))
        let archivedIDs = library.archivedEpisodeIDs
        let queuedIDs: Set = [
            "queued-unheard", "archived-queued-in-progress", "queued-in-progress",
            "archived-queued-played", "queued-played", "archived-queued-downloaded", "queued-downloaded"
        ]
        let downloadRecords = [archivedQueuedDownloaded, archivedDownloaded, queuedDownloaded, downloaded].map { episode in
            EpisodeDownloadRecord(
                episodeID: episode.episodeID,
                podcastID: episode.podcastID,
                sourceAudioURL: episode.audioURL ?? "",
                state: .completed
            )
        }
        func downloads(for filter: PodcastEpisodeFilter) -> [EpisodeDownloadRecord] {
            filter == .downloaded ? downloadRecords : unreached("download records", fallback: [])
        }

        let inboxRows: [Bool: [PodcastEpisodeFilter: [String]]] = [
            false: [
                .all: [
                    "queued-unheard", "newest", "queued-in-progress", "in-progress",
                    "queued-played", "played", "queued-downloaded", "downloaded"
                ],
                .unplayed: ["queued-unheard", "newest", "queued-in-progress", "in-progress", "queued-downloaded", "downloaded"],
                .inProgress: ["queued-in-progress", "in-progress"],
                .played: ["queued-played", "played"],
                .downloaded: ["queued-downloaded", "downloaded"]
            ],
            true: [
                .all: ["newest", "in-progress", "played", "downloaded"],
                .unplayed: ["newest", "in-progress", "downloaded"],
                .inProgress: ["in-progress"],
                .played: ["played"],
                .downloaded: ["downloaded"]
            ]
        ]
        let archiveRows: [Bool: [PodcastEpisodeFilter: [String]]] = [
            false: [
                .all: [
                    "archived-playing", "archived-unheard", "archived-queued-in-progress", "archived-in-progress",
                    "archived-queued-played", "archived-played", "archived-queued-downloaded", "archived-downloaded"
                ],
                .unplayed: [
                    "archived-playing", "archived-unheard", "archived-queued-in-progress", "archived-in-progress",
                    "archived-queued-downloaded", "archived-downloaded"
                ],
                .inProgress: ["archived-queued-in-progress", "archived-in-progress"],
                .played: ["archived-queued-played", "archived-played"],
                .downloaded: ["archived-queued-downloaded", "archived-downloaded"]
            ],
            true: [
                .all: ["archived-unheard", "archived-in-progress", "archived-played", "archived-downloaded"],
                .unplayed: ["archived-unheard", "archived-in-progress", "archived-downloaded"],
                .inProgress: ["archived-in-progress"],
                .played: ["archived-played"],
                .downloaded: ["archived-downloaded"]
            ]
        ]
        for hidesQueued in [false, true] {
            for filter in PodcastEpisodeFilter.allCases {
                // With Up Next shown the queue and the player are never read.
                func model(showsArchived: Bool, visibleEpisodeCount: Int? = nil) -> InboxEpisodeListModel {
                    makeModel(
                        filter, episodes, library,
                        hidesQueued: hidesQueued,
                        queued: hidesQueued ? queuedIDs : unreached("queued episode IDs", fallback: []),
                        playing: hidesQueued ? "archived-playing" : unreached("playing episode ID", fallback: String?.none),
                        showsArchived: showsArchived, archived: archivedIDs,
                        downloads: downloads(for: filter),
                        visibleEpisodeCount: visibleEpisodeCount
                    )
                }
                let state = "\(filter.title), Up Next \(hidesQueued ? "hidden" : "shown")"
                for (view, showsArchived, rowsByFilter) in [
                    ("Inbox", false, inboxRows[hidesQueued]),
                    ("Archive", true, archiveRows[hidesQueued])
                ] {
                    let rows = try #require(rowsByFilter?[filter], "\(view), \(state)")
                    let list = model(showsArchived: showsArchived)
                    let page = model(showsArchived: showsArchived, visibleEpisodeCount: 1)
                    #expect(list.episodes.map(\.id) == rows, "\(view), \(state)")
                    #expect(list.totalEpisodeCount == episodes.count, "\(view), \(state)")
                    #expect(!list.hasMore, "\(view), \(state)")
                    #expect(page.episodes.map(\.id) == Array(rows.prefix(1)), "\(view) page, \(state)")
                    #expect(page.hasMore == (rows.count > 1), "\(view) page, \(state)")
                    #expect(page.totalEpisodeCount == episodes.count, "\(view) page, \(state)")
                }
            }
        }

        // Groups count the rows the model kept.
        let inboxAll = makeModel(.all, episodes, library, archived: archivedIDs, downloads: downloads(for: .all))
        let archiveAll = makeModel(
            .all, episodes, library,
            showsArchived: true, archived: archivedIDs,
            downloads: downloads(for: .all)
        )
        let subscription = SubscriptionRecord(feedURL: newest.podcastID, title: "Podcast")
        #expect(InboxPodcastGroup.make(episodes: inboxAll.episodes, subscriptions: [subscription]).map(\.episodeCount) == [8])
        #expect(InboxPodcastGroup.make(episodes: archiveAll.episodes, subscriptions: [subscription]).map(\.episodeCount) == [8])
        #expect(Set(archiveAll.episodes.map(\.id)) == archivedIDs)
    }

    /// Hide Up Next applies in both views: the archive keeps an archived
    /// episode that is queued again, or playing, out while it is on.
    @Test("Hide Up Next hides queued and playing rows in both views, and either view can be filtered empty")
    func hideUpNextAppliesInBothViews() {
        let library = LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory())
        let plain = makeEpisode(id: "plain", publishedAt: 50)
        let queued = makeEpisode(id: "queued", publishedAt: 40)
        let archived = makeEpisode(id: "archived", publishedAt: 30)
        let archivedQueued = makeEpisode(id: "archived-queued", publishedAt: 20)
        let archivedPlaying = makeEpisode(id: "archived-playing", publishedAt: 10)
        let episodes = [plain, queued, archived, archivedQueued, archivedPlaying]
        let archivedIDs: Set = ["archived", "archived-queued", "archived-playing"]
        let queuedIDs: Set = ["queued", "archived-queued"]

        let inbox = makeModel(
            .all, episodes, library,
            hidesQueued: true, queued: queuedIDs, playing: "archived-playing",
            archived: archivedIDs,
            downloads: unreached("download records", fallback: [])
        )
        let archive = makeModel(
            .all, episodes, library,
            hidesQueued: true, queued: queuedIDs, playing: "archived-playing",
            showsArchived: true, archived: archivedIDs,
            downloads: unreached("download records", fallback: [])
        )
        let archiveUpNextShown = makeModel(
            .all, episodes, library,
            queued: unreached("queued episode IDs", fallback: []),
            playing: unreached("playing episode ID", fallback: nil),
            showsArchived: true, archived: archivedIDs,
            downloads: unreached("download records", fallback: [])
        )
        let everyEpisodeArchived = makeModel(
            .all, episodes, library,
            archived: Set(episodes.map(\.id)),
            downloads: unreached("download records", fallback: [])
        )
        let archiveAllHidden = makeModel(
            .all, episodes, library,
            hidesQueued: true, queued: ["archived-queued"], playing: "archived-playing",
            showsArchived: true, archived: ["archived-queued", "archived-playing"],
            downloads: unreached("download records", fallback: [])
        )

        #expect(inbox.episodes.map(\.id) == ["plain"])
        #expect(archive.episodes.map(\.id) == ["archived"])
        #expect(archiveUpNextShown.episodes.map(\.id) == ["archived", "archived-queued", "archived-playing"])
        #expect(everyEpisodeArchived.episodes.isEmpty)
        #expect(everyEpisodeArchived.totalEpisodeCount == 5)
        #expect(everyEpisodeArchived.isFilteredEmpty)
        #expect(archiveAllHidden.episodes.isEmpty)
        #expect(archiveAllHidden.totalEpisodeCount == 5)
        #expect(archiveAllHidden.isFilteredEmpty)
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

    @Test("Hiding Up Next drops queued rows and the playing episode under any filter")
    func hidesQueuedAndPlayingEpisodes() throws {
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
        // The playing episode is not in the queue; playing alone hides it.
        let queuedIDs: Set<String> = ["queued", "queued-played", "queued-downloaded"]

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

        #expect(allModel.episodes.map(\.id) == ["unqueued"])
        #expect(unplayedModel.episodes.map(\.id) == ["unqueued"])
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

    @Test("A page-limited model exposes continuation without returning later rows")
    func pageLimit() {
        let library = LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory())
        let episodes = [
            makeEpisode(id: "newest", publishedAt: 30),
            makeEpisode(id: "middle", publishedAt: 20),
            makeEpisode(id: "oldest", publishedAt: 10)
        ]

        let model = InboxEpisodeListModel.make(
            episodes: episodes,
            filter: .unplayed,
            hidesQueuedEpisodes: false,
            showsArchivedEpisodes: false,
            library: library,
            downloadRecords: [],
            queuedEpisodeIDs: [],
            playingEpisodeID: nil,
            archivedEpisodeIDs: [],
            visibleEpisodeCount: 1
        )

        #expect(model.episodes.map(\.id) == ["newest"])
        #expect(model.hasMore)
        #expect(!model.isFilteredEmpty)
    }

    private func makeModel(
        _ filter: PodcastEpisodeFilter,
        _ episodes: [EpisodeListItemSnapshot],
        _ library: LibraryStore,
        hidesQueued: Bool = false,
        queued: @autoclosure () -> Set<String> = [],
        playing: @autoclosure () -> String? = nil,
        showsArchived: Bool = false,
        archived: Set<String> = [],
        downloads: @autoclosure () -> [EpisodeDownloadRecord],
        visibleEpisodeCount: Int? = nil
    ) -> InboxEpisodeListModel {
        InboxEpisodeListModel.make(
            episodes: episodes,
            filter: filter,
            hidesQueuedEpisodes: hidesQueued,
            showsArchivedEpisodes: showsArchived,
            library: library,
            downloadRecords: downloads(),
            queuedEpisodeIDs: queued(),
            playingEpisodeID: playing(),
            archivedEpisodeIDs: archived,
            visibleEpisodeCount: visibleEpisodeCount
        )
    }

    /// All Episodes with Up Next shown, in either view: every input but the
    /// archived set fails the test if read.
    private func makeAllModel(
        _ episodes: [EpisodeListItemSnapshot],
        _ library: LibraryStore,
        showsArchived: Bool = false,
        archived: Set<String>,
        visibleEpisodeCount: Int? = nil
    ) -> InboxEpisodeListModel {
        InboxEpisodeListModel.make(
            episodes: episodes,
            filter: .all,
            hidesQueuedEpisodes: false,
            showsArchivedEpisodes: showsArchived,
            library: library,
            downloadRecords: unreached("download records", fallback: []),
            queuedEpisodeIDs: unreached("queued episode IDs", fallback: []),
            playingEpisodeID: unreached("playing episode ID", fallback: nil),
            archivedEpisodeIDs: archived,
            visibleEpisodeCount: visibleEpisodeCount
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
