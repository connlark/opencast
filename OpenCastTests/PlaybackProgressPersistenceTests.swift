import Foundation
import OpenCastCore
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Playback progress persistence")
struct PlaybackProgressPersistenceTests {
    /// A CarPlay-only launch never builds the phone scene, so persistence has to
    /// come from a process-scoped owner or a whole drive's listening is lost.
    @Test("Progress persists from a scene-independent owner")
    func persistsProgressWithoutAScene() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let appModel = OpenCastAppModel(
            localLibraryCacheStore: SQLiteLocalLibraryCacheStore.inMemory(),
            allowsAutomaticFeedRefresh: false
        )
        let episode = Episode(
            id: EpisodeID(rawValue: "persistence-episode"),
            podcastID: PodcastID(rawValue: "https://example.com/feed.xml"),
            podcastTitle: "Example Show",
            title: "Example Episode",
            duration: 600,
            audioURL: URL(string: "https://example.com/persistence-episode.mp3")
        )

        appModel.startPlaybackProgressPersistence(modelContext: context)
        try appModel.playback.load(episode, startPosition: 42)
        appModel.playback.pause()

        #expect(
            await waitUntil {
                (try? context.fetch(FetchDescriptor<EpisodeProgressRecord>()))?
                    .first { $0.episodeID == episode.id.rawValue }?
                    .position == 42
            }
        )
    }

    @Test("Flushing an unchanged episode saves nothing and bumps no updatedAt")
    func flushWithUnchangedEpisodeIsNoOp() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let appModel = OpenCastAppModel(
            localLibraryCacheStore: SQLiteLocalLibraryCacheStore.inMemory(),
            allowsAutomaticFeedRefresh: false
        )
        let episode = Episode(
            id: EpisodeID(rawValue: "no-op-flush-episode"),
            podcastID: PodcastID(rawValue: "https://example.com/feed.xml"),
            podcastTitle: "Example Show",
            title: "Example Episode",
            duration: 600,
            audioURL: URL(string: "https://example.com/no-op-flush-episode.mp3")
        )

        try appModel.playback.load(episode, startPosition: 42)
        appModel.playback.pause()
        appModel.flushPlaybackProgress(modelContext: context)

        let preferenceKey = "playback.lastEpisodeID"
        let preferences = try context.fetch(FetchDescriptor<LocalPreferenceRecord>())
            .filter { $0.key == preferenceKey }
        let record = try #require(preferences.first)
        #expect(record.value == episode.id.rawValue)
        let updatedAtAfterFirstFlush = record.updatedAt
        let selfSaveCountAfterFirstFlush = appModel.library.syncedStoreSelfSaveCount

        try await Task.sleep(for: .milliseconds(20))
        appModel.flushPlaybackProgress(modelContext: context)

        #expect(record.updatedAt == updatedAtAfterFirstFlush)
        #expect(appModel.library.syncedStoreSelfSaveCount == selfSaveCountAfterFirstFlush)
        let preferencesAfterSecondFlush = try context.fetch(FetchDescriptor<LocalPreferenceRecord>())
            .filter { $0.key == preferenceKey }
        #expect(preferencesAfterSecondFlush.count == preferences.count)
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
        for _ in 0..<120 {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }
}
