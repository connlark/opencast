import Foundation
import Testing
@testable import OpenCast

/// The UI-test seeds write through the real `upsertCache` path (finding 49);
/// this pins the fidelity that repoint bought: validators and language
/// round-trip through the same store the app reads.
@MainActor
@Suite("UI-test seed cache path")
struct UITestSeedCachePathTests {
    @Test("Seeded show round-trips etag, last-modified, and language through the real cache")
    func seededShowRoundTripsValidatorsAndLanguage() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let cacheStore = SQLiteLocalLibraryCacheStore.inMemory()

        try OpenCastUITestSeedData.seed(in: container, cacheStore: cacheStore)

        let validators = try await cacheStore.feedValidators(
            forPodcastID: OpenCastUITestSeedData.feedURL
        )
        #expect(validators?.entityTag == "\"ui-test-etag\"")
        #expect(validators?.lastModified == "Mon, 03 Aug 2026 12:00:00 GMT")

        let library = try await cacheStore.loadLibrary(
            activePodcastIDs: [OpenCastUITestSeedData.feedURL]
        )
        let podcast = try #require(
            library.podcastsByFeedURL[OpenCastUITestSeedData.feedURL]
        )
        #expect(podcast.languageCode == "en")
        #expect(podcast.title == OpenCastUITestSeedData.podcastTitle)

        let episode = try #require(
            library.episodes.first { $0.episodeID == OpenCastUITestSeedData.episodeID }
        )
        #expect(episode.title == OpenCastUITestSeedData.episodeTitle)
        #expect(episode.guid == OpenCastUITestSeedData.episodeID)
    }
}
