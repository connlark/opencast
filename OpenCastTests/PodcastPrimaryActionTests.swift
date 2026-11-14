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

    /// Archiving moves `updatedAt`, which would otherwise make the archived
    /// episode the most recently heard one.
    @Test("Resume passes over an archived in-progress episode")
    func resumeSkipsArchivedEpisodes() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let library = LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory())
        let newest = makeEpisode(id: "newest", publishedAt: 30)
        let heard = makeEpisode(id: "heard", publishedAt: 20)
        let archived = makeEpisode(id: "archived", publishedAt: 10)
        for episode in [heard, archived] {
            #expect(library.updateProgress(
                episodeID: episode.episodeID,
                podcastID: episode.podcastID,
                position: 20,
                duration: 100,
                modelContext: context
            ))
        }
        library.progressRecord(for: heard.episodeID)?.updatedAt = Date(timeIntervalSince1970: 200)
        library.progressRecord(for: archived.episodeID)?.updatedAt = Date(timeIntervalSince1970: 100)

        #expect(library.archive(archived, modelContext: context))

        #expect(PodcastPrimaryAction.resolve(episodes: [newest, heard, archived], library: library) == .resume(heard))

        #expect(library.archive(heard, modelContext: context))

        #expect(PodcastPrimaryAction.resolve(episodes: [newest, heard, archived], library: library) == .playLatest(newest))
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
