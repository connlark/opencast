import Foundation
import OpenCastCore
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Feed content recency")
struct LibraryFeedContentRecencyTests {
    @Test("Updated includes new and edited episodes, but ignores unchanged refreshes")
    func episodeChangesAdvanceContentRecency() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let cache = SQLiteLocalLibraryCacheStore.inMemory()
        let store = LibraryStore(localCache: cache)
        let feedURL = "https://example.com/recency.xml"
        let otherFeedURL = "https://example.com/other.xml"
        let initialDate = Date(timeIntervalSince1970: 1_775_390_400)
        let addedDate = initialDate.addingTimeInterval(86_400)
        let editedDate = addedDate.addingTimeInterval(86_400)
        let metadataDate = editedDate.addingTimeInterval(86_400)
        let checkedDate = editedDate.addingTimeInterval(3_600)

        context.insert(SubscriptionRecord(feedURL: feedURL, title: "Recency Show"))
        context.insert(SubscriptionRecord(feedURL: otherFeedURL, title: "Other Show"))
        try context.save()
        #expect(store.lastContentChangedAt(for: feedURL) == nil)

        let older = episode(id: "older", feedURL: feedURL, publishedAt: initialDate)
        let newer = episode(id: "newer", feedURL: feedURL, publishedAt: addedDate)
        try await cache.upsertCache(
            from: snapshot(feedURL: feedURL, episodes: [older]), refreshedAt: initialDate
        )
        try await cache.upsertCache(
            from: snapshot(feedURL: otherFeedURL, episodes: []), refreshedAt: checkedDate
        )
        try await store.reloadFromStore(modelContext: context)
        #expect(store.lastContentChangedAt(for: feedURL) == initialDate)
        #expect(store.lastContentChangedAt(for: otherFeedURL) == checkedDate)

        try await cache.upsertCache(
            from: snapshot(feedURL: feedURL, episodes: [newer, older]), refreshedAt: addedDate
        )
        try await store.reloadFromStore(modelContext: context)
        #expect(store.podcastCache(for: feedURL)?.updatedAt == initialDate)
        #expect(store.lastContentChangedAt(for: feedURL) == addedDate)

        var editedOlder = older
        editedOlder.showNotesHTML = "<p>Corrected show notes</p>"
        let editedSnapshot = snapshot(feedURL: feedURL, episodes: [newer, editedOlder])
        try await cache.upsertCache(from: editedSnapshot, refreshedAt: editedDate)
        try await store.reloadFromStore(modelContext: context)
        #expect(store.podcastCache(for: feedURL)?.updatedAt == initialDate)
        #expect(store.lastContentChangedAt(for: feedURL) == editedDate)

        try await cache.upsertCache(from: editedSnapshot, refreshedAt: checkedDate)
        try await store.reloadFromStore(modelContext: context)
        #expect(store.lastContentChangedAt(for: feedURL) == editedDate)

        let log = RefreshLogSnapshot(
            feedURL: feedURL, startedAt: checkedDate, finishedAt: checkedDate, errorMessage: nil
        )
        let health = FeedHealthStatus.derive(
            latestLog: log,
            latestSuccessAt: checkedDate,
            contentChangedAt: store.lastContentChangedAt(for: feedURL)
        )
        #expect(health.lastCheckedAt == checkedDate)
        #expect(health.lastContentChangeAt == editedDate)

        let reloadedStore = LibraryStore(localCache: cache)
        try await reloadedStore.reloadFromStore(modelContext: context)
        #expect(reloadedStore.lastContentChangedAt(for: feedURL) == editedDate)

        try await cache.upsertCache(
            from: snapshot(feedURL: feedURL, title: "Renamed Show", episodes: [newer, editedOlder]),
            refreshedAt: metadataDate
        )
        try await store.reloadFromStore(modelContext: context)
        #expect(store.lastContentChangedAt(for: feedURL) == metadataDate)

    }

    private func snapshot(
        feedURL: String, title: String = "Recency Show", episodes: [Episode]
    ) -> FeedSnapshot {
        FeedSnapshot(
            podcast: Podcast(
                id: PodcastID(rawValue: feedURL), feedURL: URL(string: feedURL)!, title: title
            ),
            episodes: episodes
        )
    }

    private func episode(id: String, feedURL: String, publishedAt: Date) -> Episode {
        Episode(
            id: EpisodeID(rawValue: id),
            podcastID: PodcastID(rawValue: feedURL),
            podcastTitle: "Recency Show",
            title: id,
            publishedAt: publishedAt,
            audioURL: URL(string: "https://example.com/\(id).mp3"),
            guid: id
        )
    }
}
