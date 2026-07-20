import Foundation
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Podcast primary action")
struct PodcastPrimaryActionTests {
    @Test("Most recently updated in-progress episode resumes")
    func resolvesMostRecentInProgressEpisode() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let library = LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory())
        let newest = makeEpisode(id: "newest", publishedAt: 30)
        let recentProgress = makeEpisode(id: "recent-progress", publishedAt: 20)
        let olderProgress = makeEpisode(id: "older-progress", publishedAt: 10)

        #expect(
            library.updateProgress(
                episodeID: recentProgress.episodeID,
                podcastID: recentProgress.podcastID,
                position: 20,
                duration: 100,
                modelContext: context
            )
        )
        #expect(
            library.updateProgress(
                episodeID: olderProgress.episodeID,
                podcastID: olderProgress.podcastID,
                position: 10,
                duration: 100,
                modelContext: context
            )
        )
        library.progressRecord(for: recentProgress.episodeID)?.updatedAt = Date(timeIntervalSince1970: 200)
        library.progressRecord(for: olderProgress.episodeID)?.updatedAt = Date(timeIntervalSince1970: 100)

        let action = PodcastPrimaryAction.resolve(
            episodes: [newest, recentProgress, olderProgress],
            library: library
        )

        #expect(action == .resume(recentProgress))
    }

    @Test("Play Latest prefers the newest unplayed episode")
    func resolvesNewestUnplayedEpisode() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let library = LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory())
        let newest = makeEpisode(id: "newest", publishedAt: 30)
        let next = makeEpisode(id: "next", publishedAt: 20)
        #expect(library.markEpisodePlayed(newest, modelContext: context))

        let action = PodcastPrimaryAction.resolve(episodes: [newest, next], library: library)

        #expect(action == .playLatest(next))
    }

    @Test("An all-played podcast still offers its newest episode")
    func allPlayedFallback() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let library = LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory())
        let newest = makeEpisode(id: "newest", publishedAt: 30)
        let older = makeEpisode(id: "older", publishedAt: 20)
        #expect(library.markEpisodePlayed(newest, modelContext: context))
        #expect(library.markEpisodePlayed(older, modelContext: context))

        #expect(PodcastPrimaryAction.resolve(episodes: [newest, older], library: library) == .playLatest(newest))
        #expect(PodcastPrimaryAction.resolve(episodes: [], library: library) == nil)
    }

    private func makeEpisode(id: String, publishedAt: TimeInterval) -> EpisodeListItemSnapshot {
        EpisodeListItemSnapshot(
            episodeID: id,
            podcastID: "https://example.com/feed.xml",
            podcastTitle: "Podcast",
            title: "Episode \(id)",
            summary: nil,
            publishedAt: Date(timeIntervalSince1970: publishedAt),
            duration: 100,
            audioURL: "https://example.com/\(id).mp3",
            artworkURL: nil,
            artworkPreview: nil,
            guid: id,
            cachedAt: .now
        )
    }
}
