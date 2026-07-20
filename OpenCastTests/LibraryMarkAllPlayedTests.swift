import Foundation
import OpenCastCore
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Library mark all played")
struct LibraryMarkAllPlayedTests {
    @Test("Bulk marking updates target records, inserts missing progress, and is idempotent")
    func updatesOnlyTargetPodcastAndBecomesNoOp() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let cache = SQLiteLocalLibraryCacheStore.inMemory()
        let podcastID = "https://example.com/target.xml"
        let otherPodcastID = "https://example.com/other.xml"
        try await cache.upsertCache(
            from: makeFeedSnapshot(
                podcastID: podcastID,
                episodes: [("existing", 120), ("unknown-duration", nil)]
            ),
            refreshedAt: .now
        )
        context.insert(SubscriptionRecord(feedURL: podcastID, title: "Target Show"))
        context.insert(SubscriptionRecord(feedURL: otherPodcastID, title: "Other Show"))
        let existing = EpisodeProgressRecord(
            episodeID: "existing",
            podcastID: podcastID,
            position: 30,
            duration: 120
        )
        let other = EpisodeProgressRecord(
            episodeID: "other",
            podcastID: otherPodcastID,
            position: 45,
            duration: 180
        )
        context.insert(existing)
        context.insert(other)
        try context.save()
        let library = LibraryStore(localCache: cache)
        await library.load(modelContext: context)

        #expect(library.markAllPlayed(forPodcastID: podcastID, modelContext: context))

        let progressRecords = try context.fetch(FetchDescriptor<EpisodeProgressRecord>())
        let unknownDuration = try #require(
            progressRecords.first { $0.episodeID == "unknown-duration" }
        )
        #expect(existing.position == 120)
        #expect(existing.duration == 120)
        #expect(existing.isPlayed)
        #expect(unknownDuration.position == 0)
        #expect(unknownDuration.duration == nil)
        #expect(unknownDuration.isPlayed)
        #expect(other.position == 45)
        #expect(other.duration == 180)
        #expect(!other.isPlayed)
        let updatedAtAfterFirstCall = existing.updatedAt

        #expect(!library.markAllPlayed(forPodcastID: podcastID, modelContext: context))
        #expect(existing.updatedAt == updatedAtAfterFirstCall)
    }

    @Test("Bulk marking retains deterministic equal-date duplicate selection")
    func duplicateSelection() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let cache = SQLiteLocalLibraryCacheStore.inMemory()
        let podcastID = "https://example.com/duplicates.xml"
        try await cache.upsertCache(
            from: makeFeedSnapshot(podcastID: podcastID, episodes: [("duplicate", 300)]),
            refreshedAt: .now
        )
        context.insert(SubscriptionRecord(feedURL: podcastID, title: "Duplicate Show"))
        // A tie in the past: marking stamps the winner with `.now`, which must
        // then beat the losing duplicate in the latest-record index. A future
        // tie date would make the untouched loser outrank the marked record.
        let tiedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let deterministicallySelected = EpisodeProgressRecord(
            episodeID: "duplicate",
            podcastID: podcastID,
            position: 10,
            duration: 300,
            updatedAt: tiedDate
        )
        let duplicate = EpisodeProgressRecord(
            episodeID: "duplicate",
            podcastID: podcastID,
            position: 20,
            duration: 300,
            updatedAt: tiedDate
        )
        context.insert(duplicate)
        context.insert(deterministicallySelected)
        try context.save()
        let library = LibraryStore(localCache: cache)
        await library.load(modelContext: context)

        #expect(library.markAllPlayed(forPodcastID: podcastID, modelContext: context))

        #expect(deterministicallySelected.position == 300)
        #expect(deterministicallySelected.isPlayed)
        #expect(duplicate.position == 20)
        #expect(!duplicate.isPlayed)
        #expect(
            library.progressRecord(for: "duplicate")?.persistentModelID
                == deterministicallySelected.persistentModelID
        )
    }

    private func makeFeedSnapshot(
        podcastID: String,
        episodes: [(id: String, duration: TimeInterval?)]
    ) throws -> FeedSnapshot {
        let feedURL = try #require(URL(string: podcastID))
        let podcast = Podcast(
            id: PodcastID(rawValue: podcastID),
            feedURL: feedURL,
            title: "Bulk Progress Show"
        )
        return FeedSnapshot(
            podcast: podcast,
            episodes: episodes.map { fixture in
                Episode(
                    id: EpisodeID(rawValue: fixture.id),
                    podcastID: podcast.id,
                    podcastTitle: podcast.title,
                    title: "Episode \(fixture.id)",
                    publishedAt: .now,
                    duration: fixture.duration,
                    audioURL: URL(string: "https://example.com/\(fixture.id).mp3"),
                    guid: fixture.id
                )
            }
        )
    }
}
