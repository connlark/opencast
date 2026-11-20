import Foundation
import OpenCastCore
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("CarPlay browse model builder")
struct CarPlayBrowseModelBuilderTests {
    private static let podcastID = "https://example.com/feed.xml"
    private static let podcastTitle = "Test Show"
    private static let floorLimits = CarPlayListLimits(maximumItemCount: 12, maximumSectionCount: 2)
    private static let roomyLimits = CarPlayListLimits(maximumItemCount: 100, maximumSectionCount: 10)

    @Test("Up Next preserves queue order, skips missing episodes, and respects the item cap")
    func upNextOrderResolutionAndCap() async throws {
        let fixture = try await makeFixture(episodeCount: 20)
        let episodeIDs = [episodeID(19), "missing"] + (0..<13).map(episodeID)
        let queueItems = episodeIDs.enumerated().map { index, episodeID in
            UpNextQueueItem(
                episodeID: episodeID,
                podcastID: Self.podcastID,
                sequence: index,
                enqueuedAt: Date(timeIntervalSince1970: Double(index))
            )
        }

        let snapshot = CarPlayBrowseModelBuilder.upNext(
            queueItems: queueItems,
            library: fixture.library,
            downloadRecords: [],
            nowPlaying: .idle,
            limits: Self.floorLimits.withoutContinuation
        )

        #expect(snapshot.title == "Up Next")
        #expect(snapshot.rowCount == 12)
        #expect(self.episodeIDs(in: snapshot) == [episodeID(19)] + (0..<11).map(episodeID))
        #expect(snapshot.continuation == nil)
        #expect(!snapshot.sections.contains { $0.rows.contains(.showMore) })
    }

    @Test("Continue section is added only when an episode is loaded and counts against the cap")
    func continueSection() async throws {
        let fixture = try await makeFixture(episodeCount: 20)
        let loaded = try #require(fixture.library.episode(with: episodeID(5)))

        let withoutContinue = CarPlayBrowseModelBuilder.inbox(
            library: fixture.library,
            downloadRecords: [],
            currentEpisode: nil,
            nowPlaying: .idle,
            isLoading: false,
            limits: Self.floorLimits
        )
        let withContinue = CarPlayBrowseModelBuilder.inbox(
            library: fixture.library,
            downloadRecords: [],
            currentEpisode: fixture.library.domainEpisode(for: loaded),
            nowPlaying: CarPlayNowPlayingState(episodeID: loaded.episodeID, isPlaying: true),
            isLoading: false,
            limits: Self.floorLimits
        )

        #expect(withoutContinue.sections.map(\.header) == [nil])
        #expect(withContinue.sections.map(\.header) == ["Continue", "Latest"])
        #expect(withContinue.rowCount == 12)
        #expect(withContinue.sections[0].rows.count == 1)
        #expect(episodeIDs(in: withContinue) == [episodeID(5)] + (0..<10).map(episodeID))
        #expect(withContinue.sections[1].rows.last == .showMore)
    }

    @Test("Show More appears only past the cap and reaches one further page")
    func showMoreContinuation() async throws {
        let exactFit = try await makeFixture(episodeCount: 12)
        let overflowing = try await makeFixture(episodeCount: 30)

        let fitting = CarPlayBrowseModelBuilder.inbox(
            library: exactFit.library,
            downloadRecords: [],
            currentEpisode: nil,
            nowPlaying: .idle,
            isLoading: false,
            limits: Self.floorLimits
        )
        let truncated = CarPlayBrowseModelBuilder.inbox(
            library: overflowing.library,
            downloadRecords: [],
            currentEpisode: nil,
            nowPlaying: .idle,
            isLoading: false,
            limits: Self.floorLimits
        )

        #expect(fitting.rowCount == 12)
        #expect(fitting.continuation == nil)
        #expect(!fitting.sections.contains { $0.rows.contains(.showMore) })

        let continuation = try #require(truncated.continuation)
        #expect(continuation.title == "More Episodes")
        #expect(continuation.sections.count == 1)
        #expect(episodeIDs(in: continuation.snapshot) == (11..<23).map(episodeID))
        #expect(continuation.snapshot.rowCount == 12)
        #expect(continuation.snapshot.continuation == nil)
        #expect(!continuation.sections.contains { $0.rows.contains(.showMore) })
    }

    @Test("Inbox leaves archived episodes out without spending a slot on them")
    func inboxSkipsArchivedEpisodesBeforeTheCap() async throws {
        let fixture = try await makeFixture(episodeCount: 30)
        let archived = try (0..<10).map { index in
            try #require(fixture.library.episode(with: episodeID(index)))
        }
        #expect(fixture.library.archive(archived, modelContext: fixture.context))

        let snapshot = CarPlayBrowseModelBuilder.inbox(
            library: fixture.library,
            downloadRecords: [],
            currentEpisode: nil,
            nowPlaying: .idle,
            isLoading: false,
            limits: Self.floorLimits
        )

        #expect(snapshot.rowCount == 12)
        #expect(episodeIDs(in: snapshot) == (10..<21).map(episodeID))
        #expect(snapshot.sections[0].rows.last == .showMore)
        let continuation = try #require(snapshot.continuation)
        #expect(episodeIDs(in: continuation.snapshot) == (21..<30).map(episodeID))
    }

    @Test("An archived current episode stays in Continue and leaves Latest")
    func archivedCurrentEpisodeStaysInContinue() async throws {
        let fixture = try await makeFixture(episodeCount: 20)
        let loaded = try #require(fixture.library.episode(with: episodeID(5)))
        #expect(fixture.library.archive(loaded, modelContext: fixture.context))

        let snapshot = CarPlayBrowseModelBuilder.inbox(
            library: fixture.library,
            downloadRecords: [],
            currentEpisode: fixture.library.domainEpisode(for: loaded),
            nowPlaying: CarPlayNowPlayingState(episodeID: loaded.episodeID, isPlaying: true),
            isLoading: false,
            limits: Self.floorLimits
        )

        #expect(snapshot.sections.map(\.header) == ["Continue", "Latest"])
        #expect(snapshot.sections[0].rows.compactMap { episodeRow($0)?.episodeID } == [loaded.episodeID])
        #expect(!snapshot.sections[1].rows.contains { episodeRow($0)?.episodeID == loaded.episodeID })
        #expect(episodeIDs(in: snapshot) == [episodeID(5)] + (Array(0..<5) + Array(6..<11)).map(episodeID))
        #expect(snapshot.sections[1].rows.last == .showMore)
    }

    @Test("A list that cannot push a further page fills every slot with rows")
    func truncationWithoutMarker() async throws {
        let fixture = try await makeFixture(episodeCount: 30)

        let pushedFromNowPlaying = CarPlayBrowseModelBuilder.inbox(
            library: fixture.library,
            downloadRecords: [],
            currentEpisode: nil,
            nowPlaying: .idle,
            isLoading: false,
            limits: Self.floorLimits.withoutContinuation
        )

        #expect(pushedFromNowPlaying.rowCount == 12)
        #expect(pushedFromNowPlaying.continuation == nil)
        #expect(!pushedFromNowPlaying.sections.contains { $0.rows.contains(.showMore) })
        #expect(episodeIDs(in: pushedFromNowPlaying) == (0..<12).map(episodeID))
    }

    @Test("Rows carry playing, progress, and downloaded state")
    func rowStateMapping() async throws {
        let fixture = try await makeFixture(episodeCount: 4)
        let playing = try #require(fixture.library.episode(with: episodeID(0)))
        let inProgress = try #require(fixture.library.episode(with: episodeID(1)))
        let downloaded = try #require(fixture.library.episode(with: episodeID(2)))

        #expect(
            fixture.library.updateProgress(
                episodeID: inProgress.episodeID,
                podcastID: inProgress.podcastID,
                position: 25,
                duration: 100,
                modelContext: fixture.context
            )
        )

        let snapshot = CarPlayBrowseModelBuilder.inbox(
            library: fixture.library,
            downloadRecords: [makeDownloadRecord(episodeID: downloaded.episodeID, state: .completed)],
            currentEpisode: fixture.library.domainEpisode(for: playing),
            nowPlaying: CarPlayNowPlayingState(episodeID: playing.episodeID, isPlaying: true),
            isLoading: false,
            limits: Self.roomyLimits
        )
        let latestRows = try #require(snapshot.sections.last?.rows)

        #expect(episodeRow(latestRows[0])?.isPlaying == true)
        // A playing row carries no bar: its progress record churns while it plays.
        #expect(episodeRow(latestRows[0])?.playbackProgress == nil)
        #expect(episodeRow(latestRows[1])?.playbackProgress == 0.25)
        #expect(episodeRow(latestRows[1])?.isPlaying == false)
        #expect(episodeRow(latestRows[1])?.detailText == Self.podcastTitle)
        #expect(episodeRow(latestRows[2])?.isDownloaded == true)
        #expect(episodeRow(latestRows[3])?.isDownloaded == false)
        #expect(episodeRow(latestRows[3])?.playbackProgress == nil)
    }

    @Test("A loaded but paused episode shows progress instead of the playing indicator")
    func pausedEpisodeIsNotMarkedPlaying() async throws {
        let fixture = try await makeFixture(episodeCount: 3)
        let restored = try #require(fixture.library.episode(with: episodeID(0)))

        #expect(
            fixture.library.updateProgress(
                episodeID: restored.episodeID,
                podcastID: restored.podcastID,
                position: 40,
                duration: 100,
                modelContext: fixture.context
            )
        )

        let snapshot = CarPlayBrowseModelBuilder.inbox(
            library: fixture.library,
            downloadRecords: [],
            currentEpisode: fixture.library.domainEpisode(for: restored),
            nowPlaying: CarPlayNowPlayingState(episodeID: restored.episodeID, isPlaying: false),
            isLoading: false,
            limits: Self.roomyLimits
        )
        let continueRow = try #require(episodeRow(snapshot.sections[0].rows[0]))
        let latestRow = try #require(episodeRow(snapshot.sections[1].rows[0]))

        #expect(!continueRow.isPlaying)
        #expect(!latestRow.isPlaying)
        #expect(latestRow.playbackProgress == 0.4)
    }

    @Test("Per-show list honors the stored filter and sort order")
    func perShowFilterAndSort() async throws {
        let fixture = try await makeFixture(episodeCount: 3)
        let settings = PodcastEpisodeListSettingsStore()
        let played = try #require(fixture.library.episode(with: episodeID(1)))

        #expect(fixture.library.markEpisodePlayed(played, modelContext: fixture.context))

        let defaults = CarPlayBrowseModelBuilder.episodes(
            forPodcastID: Self.podcastID,
            title: Self.podcastTitle,
            library: fixture.library,
            downloadRecords: [],
            episodeListSettings: settings,
            nowPlaying: .idle,
            limits: Self.roomyLimits
        )

        #expect(defaults.title == Self.podcastTitle)
        #expect(episodeIDs(in: defaults) == (0..<3).map(episodeID))

        settings.setFilter(.unplayed, forPodcastID: Self.podcastID, modelContext: fixture.context)
        settings.setSortOrder(.oldestFirst, forPodcastID: Self.podcastID, modelContext: fixture.context)
        let filtered = CarPlayBrowseModelBuilder.episodes(
            forPodcastID: Self.podcastID,
            title: Self.podcastTitle,
            library: fixture.library,
            downloadRecords: [],
            episodeListSettings: settings,
            nowPlaying: .idle,
            limits: Self.roomyLimits
        )

        #expect(episodeIDs(in: filtered) == [episodeID(2), episodeID(0)])
        let oldest = try #require(fixture.library.episode(with: episodeID(2)))
        #expect(
            episodeRow(filtered.sections[0].rows[0])?.detailText
                == oldest.publishedAt?.formatted(.dateTime.month(.abbreviated).day().year())
        )
    }

    @Test("Downloads shows completed downloads newest first, including orphans")
    func downloadsBucket() async throws {
        let fixture = try await makeFixture(episodeCount: 2)
        let libraryEpisode = try #require(fixture.library.episode(with: episodeID(0)))
        let orphan = EpisodeDownloadRecord(
            episodeID: "orphan",
            podcastID: "https://example.com/removed.xml",
            sourceAudioURL: "https://cdn.example.com/orphan.mp3",
            state: .completed,
            episodeTitle: "Orphan Episode",
            podcastTitle: "Removed Podcast",
            updatedAt: Date(timeIntervalSince1970: 500)
        )

        let snapshot = CarPlayBrowseModelBuilder.downloads(
            records: [
                makeDownloadRecord(
                    episodeID: libraryEpisode.episodeID,
                    state: .completed,
                    updatedAt: Date(timeIntervalSince1970: 100)
                ),
                makeDownloadRecord(episodeID: episodeID(1), state: .downloading),
                orphan
            ],
            library: fixture.library,
            nowPlaying: .idle,
            isLoading: false,
            limits: Self.roomyLimits
        )

        #expect(snapshot.title == "Downloads")
        #expect(episodeIDs(in: snapshot) == ["orphan", libraryEpisode.episodeID])
        let orphanRow = try #require(episodeRow(snapshot.sections[0].rows[0]))
        #expect(orphanRow.title == "Orphan Episode")
        #expect(orphanRow.detailText == "Removed Podcast")
        #expect(orphanRow.isDownloaded)
    }

    @Test("Library leads with the Playlists row only when asked, inside the same cap")
    func libraryLeadsWithPlaylistsRowOnlyWhenRequested() async throws {
        let fixture = try await makeFixture(episodeCount: 1)
        let subscriptions = fixture.library.subscriptions + (1..<14).map { index in
            SubscriptionRecord(
                feedURL: "https://example.com/extra-\(index).xml",
                title: "Extra Show \(index)",
                artworkURL: "https://example.com/extra-\(index).jpg"
            )
        }

        let withPlaylists = CarPlayBrowseModelBuilder.library(
            subscriptions: subscriptions,
            library: fixture.library,
            showsPlaylistsRow: true,
            isLoading: false,
            limits: .fallback
        )
        let withoutPlaylists = CarPlayBrowseModelBuilder.library(
            subscriptions: subscriptions,
            library: fixture.library,
            showsPlaylistsRow: false,
            isLoading: false,
            limits: .fallback
        )

        #expect(withPlaylists.sections.count == 1)
        let rows = withPlaylists.sections[0].rows
        #expect(rows.first == .playlists)
        #expect(rows.last == .showMore)
        #expect(withPlaylists.rowCount == 12)
        #expect(podcastRow(rows[1])?.feedURL == Self.podcastID)
        #expect(withPlaylists.continuation?.title == "More Shows")
        #expect(withPlaylists.continuation?.sections.flatMap(\.rows).contains(.playlists) == false)

        #expect(!withoutPlaylists.sections.flatMap(\.rows).contains(.playlists))
        #expect(withoutPlaylists.continuation?.sections.flatMap(\.rows).contains(.playlists) == false)
        #expect(podcastRow(withoutPlaylists.sections[0].rows[0])?.feedURL == Self.podcastID)
    }

    @Test("The playlists list keeps the store's order and pages at the floor limits")
    func playlistsListRespectsFloorLimitsWithContinuation() throws {
        let summaries = (0..<13).map { index in
            makePlaylistSummary(playlistID: "playlist-\(index)", name: "Playlist \(index)", kind: .manual)
        }

        let snapshot = CarPlayBrowseModelBuilder.playlists(
            summaries,
            episodeCount: { _ in 2 },
            artworkURL: { _ in nil },
            limits: .fallback
        )

        #expect(snapshot.title == "Playlists")
        #expect(snapshot.sections.count == 1)
        #expect(snapshot.sections[0].header == nil)
        #expect(snapshot.rowCount == 12)
        let rows = snapshot.sections[0].rows
        #expect(rows.compactMap(playlistRow).map(\.playlistID) == (0..<11).map { "playlist-\($0)" })
        #expect(rows.last == .showMore)
        let continuation = try #require(snapshot.continuation)
        #expect(continuation.title == "More Playlists")
        #expect(continuation.sections.flatMap(\.rows).compactMap(playlistRow).map(\.playlistID) == ["playlist-11", "playlist-12"])
        #expect(continuation.snapshot.continuation == nil)
    }

    @Test("A playlist's episodes keep input order, carry the playlist and show title, and page like any list")
    func playlistEpisodesKeepOrderTagAndShowTitle() async throws {
        let fixture = try await makeFixture(episodeCount: 13)
        let orderedIDs = [episodeID(4), episodeID(0)] + (0..<13).filter { $0 != 0 && $0 != 4 }.map(episodeID)
        let episodes = try orderedIDs.map { try #require(fixture.library.episode(with: $0)) }

        let snapshot = CarPlayBrowseModelBuilder.playlistEpisodes(
            playlistID: "playlist-commute",
            title: "Commute",
            episodes: episodes,
            hidesPlayed: false,
            library: fixture.library,
            downloadRecords: [],
            nowPlaying: .idle,
            limits: Self.floorLimits
        )
        let empty = CarPlayBrowseModelBuilder.playlistEpisodes(
            playlistID: "playlist-empty",
            title: "Empty",
            episodes: [],
            hidesPlayed: false,
            library: fixture.library,
            downloadRecords: [],
            nowPlaying: .idle,
            limits: Self.floorLimits
        )

        #expect(snapshot.title == "Commute")
        #expect(snapshot.rowCount == 12)
        #expect(episodeIDs(in: snapshot) == Array(orderedIDs.prefix(11)))
        #expect(snapshot.sections.last?.rows.last == .showMore)
        let visibleRows = snapshot.sections.flatMap(\.rows).compactMap(episodeRow)
        #expect(visibleRows.allSatisfy { $0.sourcePlaylistID == "playlist-commute" })
        #expect(visibleRows.allSatisfy { $0.detailText == Self.podcastTitle })
        let continuation = try #require(snapshot.continuation)
        #expect(continuation.title == "More Episodes")
        #expect(episodeIDs(in: continuation.snapshot) == Array(orderedIDs.dropFirst(11)))
        #expect(continuation.sections.flatMap(\.rows).compactMap(episodeRow).allSatisfy { $0.sourcePlaylistID == "playlist-commute" })

        #expect(empty.title == "Empty")
        #expect(empty.sections.isEmpty)
        #expect(empty.rowCount == 0)
        #expect(empty.continuation == nil)
        #expect(empty.emptyTitleVariants.first == "Nothing to Play")
        #expect(empty.emptySubtitleVariants == ["This playlist has no episodes to play."])
    }

    @Test("A playlist's episodes drop played rows only when it hides played")
    func playlistEpisodesHonourHidesPlayed() async throws {
        let fixture = try await makeFixture(episodeCount: 3)
        let episodes = try (0..<3).map { try #require(fixture.library.episode(with: episodeID($0))) }
        #expect(fixture.library.markEpisodePlayed(episodes[1], modelContext: fixture.context))

        let hiding = CarPlayBrowseModelBuilder.playlistEpisodes(
            playlistID: "playlist-commute",
            title: "Commute",
            episodes: episodes,
            hidesPlayed: true,
            library: fixture.library,
            downloadRecords: [],
            nowPlaying: .idle,
            limits: Self.roomyLimits
        )
        let showing = CarPlayBrowseModelBuilder.playlistEpisodes(
            playlistID: "playlist-commute",
            title: "Commute",
            episodes: episodes,
            hidesPlayed: false,
            library: fixture.library,
            downloadRecords: [],
            nowPlaying: .idle,
            limits: Self.roomyLimits
        )

        #expect(episodeIDs(in: hiding) == [episodeID(0), episodeID(2)])
        #expect(episodeIDs(in: showing) == (0..<3).map(episodeID))
    }

    private func makeFixture(
        episodeCount: Int
    ) async throws -> (library: LibraryStore, context: ModelContext) {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let cache = SQLiteLocalLibraryCacheStore.inMemory()
        try await cache.upsertCache(
            from: makeFeedSnapshot(episodeCount: episodeCount),
            refreshedAt: .now
        )
        context.insert(
            SubscriptionRecord(
                feedURL: Self.podcastID,
                title: Self.podcastTitle,
                artworkURL: "https://example.com/art.jpg"
            )
        )
        try context.save()
        let library = LibraryStore(localCache: cache)
        await library.load(modelContext: context)
        return (library, context)
    }

    private func makeFeedSnapshot(episodeCount: Int) throws -> FeedSnapshot {
        let feedURL = try #require(URL(string: Self.podcastID))
        let podcast = Podcast(
            id: PodcastID(rawValue: Self.podcastID),
            feedURL: feedURL,
            title: Self.podcastTitle,
            artworkURL: URL(string: "https://example.com/art.jpg")
        )
        return FeedSnapshot(
            podcast: podcast,
            episodes: (0..<episodeCount).map { index in
                Episode(
                    id: EpisodeID(rawValue: episodeID(index)),
                    podcastID: podcast.id,
                    podcastTitle: podcast.title,
                    title: "Episode \(index)",
                    publishedAt: Date(timeIntervalSince1970: Double(episodeCount - index) * 1_000),
                    duration: 100,
                    audioURL: URL(string: "https://example.com/\(episodeID(index)).mp3"),
                    guid: episodeID(index)
                )
            }
        )
    }

    private func makeDownloadRecord(
        episodeID: String,
        state: EpisodeDownloadState,
        updatedAt: Date = Date(timeIntervalSince1970: 0)
    ) -> EpisodeDownloadRecord {
        EpisodeDownloadRecord(
            episodeID: episodeID,
            podcastID: Self.podcastID,
            sourceAudioURL: "https://example.com/\(episodeID).mp3",
            state: state,
            episodeTitle: "Episode \(episodeID)",
            podcastTitle: Self.podcastTitle,
            updatedAt: updatedAt
        )
    }

    private func episodeID(_ index: Int) -> String {
        "episode-\(index)"
    }

    private func episodeIDs(in snapshot: CarPlayBrowseSnapshot) -> [String] {
        snapshot.sections.flatMap(\.rows).compactMap { row in
            switch row {
            case .episode(let episodeRow):
                episodeRow.episodeID
            case .podcast, .playlists, .playlist, .showMore:
                nil
            }
        }
    }

    private func episodeRow(_ row: CarPlayListRow) -> CarPlayEpisodeRow? {
        guard case .episode(let episodeRow) = row else {
            return nil
        }
        return episodeRow
    }

    private func podcastRow(_ row: CarPlayListRow) -> CarPlayPodcastRow? {
        guard case .podcast(let podcastRow) = row else {
            return nil
        }
        return podcastRow
    }

    private func playlistRow(_ row: CarPlayListRow) -> CarPlayPlaylistRow? {
        guard case .playlist(let playlistRow) = row else {
            return nil
        }
        return playlistRow
    }

    private func makePlaylistSummary(
        playlistID: String,
        name: String,
        kind: PlaylistKind
    ) -> PlaylistSummary {
        PlaylistSummary(
            playlistID: playlistID,
            name: name,
            kind: kind,
            rule: kind == .smart ? PlaylistRule.default : nil,
            hidesPlayed: false,
            origin: .user,
            itemCount: 0,
            totalDuration: 0,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            coverPodcastIDs: []
        )
    }
}
