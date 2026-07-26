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

    @Test("Inbox keeps newest-first order and slices to the item cap")
    func inboxOrderAndSlicing() async throws {
        let fixture = try await makeFixture(episodeCount: 20)

        let snapshot = CarPlayBrowseModelBuilder.inbox(
            library: fixture.library,
            downloadRecords: [],
            currentEpisode: nil,
            nowPlaying: .idle,
            isLoading: false,
            limits: Self.floorLimits
        )

        #expect(snapshot.title == "Inbox")
        #expect(snapshot.sections.count == 1)
        #expect(snapshot.sections[0].header == nil)
        #expect(snapshot.rowCount == 12)
        // 11 episodes plus the marker in the twelfth slot.
        #expect(episodeIDs(in: snapshot) == (0..<11).map(episodeID))
        #expect(snapshot.sections[0].rows.last == .showMore)
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
        // The Continue row spends one of the twelve slots, so ten latest rows
        // plus the marker follow it.
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
        // The tail resumes exactly where the visible page stopped, is itself
        // capped, and never nests another marker.
        #expect(episodeIDs(in: continuation.snapshot) == (11..<23).map(episodeID))
        #expect(continuation.snapshot.rowCount == 12)
        #expect(continuation.snapshot.continuation == nil)
        #expect(!continuation.sections.contains { $0.rows.contains(.showMore) })
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
        // The slot the marker would have taken carries a twelfth episode.
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
        // The loaded episode's progress record churns while it plays, so its row
        // deliberately carries no bar.
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

        // The CarPlay cold restore leaves an episode loaded and paused, which is
        // exactly when a playing indicator would be a lie.
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

    @Test("Library lists subscriptions with their artwork")
    func librarySubscriptions() async throws {
        let fixture = try await makeFixture(episodeCount: 1)

        let snapshot = CarPlayBrowseModelBuilder.library(
            subscriptions: fixture.library.subscriptions,
            library: fixture.library,
            isLoading: false,
            limits: Self.roomyLimits
        )

        #expect(snapshot.title == "Library")
        #expect(snapshot.sections.count == 1)
        let row = try #require(podcastRow(snapshot.sections[0].rows[0]))
        #expect(row.feedURL == Self.podcastID)
        #expect(row.title == Self.podcastTitle)
        #expect(row.artworkURL == "https://example.com/art.jpg")
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
        // Per-show rows trade the podcast title for the publish date, which the
        // show list already implies.
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

    @Test("Empty lists carry their own empty-state copy, and loading lists spin")
    func emptyAndLoadingStates() async throws {
        let fixture = try await makeFixture(episodeCount: 0)

        let empty = CarPlayBrowseModelBuilder.inbox(
            library: fixture.library,
            downloadRecords: [],
            currentEpisode: nil,
            nowPlaying: .idle,
            isLoading: false,
            limits: Self.roomyLimits
        )
        let loading = CarPlayBrowseModelBuilder.downloads(
            records: [],
            library: fixture.library,
            nowPlaying: .idle,
            isLoading: true,
            limits: Self.roomyLimits
        )

        #expect(empty.sections.isEmpty)
        #expect(empty.rowCount == 0)
        #expect(empty.continuation == nil)
        #expect(empty.emptyTitleVariants == ["No Episodes Yet", "No Episodes"])
        #expect(empty.emptySubtitleVariants == ["New episodes from your shows appear here."])
        #expect(!empty.showsSpinnerWhileEmpty)
        #expect(loading.emptyTitleVariants == ["Loading…"])
        #expect(loading.emptySubtitleVariants.isEmpty)
        #expect(loading.showsSpinnerWhileEmpty)
    }

    @Test("Snapshots compare equal until a row actually changes")
    func snapshotEquality() async throws {
        let fixture = try await makeFixture(episodeCount: 3)
        let changed = try #require(fixture.library.episode(with: episodeID(2)))

        let first = CarPlayBrowseModelBuilder.inbox(
            library: fixture.library,
            downloadRecords: [],
            currentEpisode: nil,
            nowPlaying: .idle,
            isLoading: false,
            limits: Self.roomyLimits
        )
        let repeated = CarPlayBrowseModelBuilder.inbox(
            library: fixture.library,
            downloadRecords: [],
            currentEpisode: nil,
            nowPlaying: .idle,
            isLoading: false,
            limits: Self.roomyLimits
        )

        #expect(first == repeated)

        let afterDownload = CarPlayBrowseModelBuilder.inbox(
            library: fixture.library,
            downloadRecords: [makeDownloadRecord(episodeID: changed.episodeID, state: .completed)],
            currentEpisode: nil,
            nowPlaying: .idle,
            isLoading: false,
            limits: Self.roomyLimits
        )

        #expect(first != afterDownload)
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
            case .podcast, .showMore:
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
}
