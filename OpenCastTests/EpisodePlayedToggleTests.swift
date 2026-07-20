import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Episode played toggle")
struct EpisodePlayedToggleTests {
    @Test("Unplayed toggles to played through app-model playback semantics")
    func unplayedToPlayed() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let episode = makeEpisode(id: "toggle-to-played")
        context.insert(LocalPreferenceRecord(key: "playback.lastEpisodeID", value: episode.episodeID))
        try context.save()
        let appModel = OpenCastAppModel(localLibraryCacheStore: SQLiteLocalLibraryCacheStore.inMemory())
        await appModel.library.load(modelContext: context)
        try appModel.playback.load(appModel.library.domainEpisode(for: episode), startPosition: 30)

        #expect(appModel.toggleEpisodePlayed(episode, modelContext: context))

        let progressRecords = try context.fetch(FetchDescriptor<EpisodeProgressRecord>())
        let lastEpisodePreferences = try context.fetch(FetchDescriptor<LocalPreferenceRecord>())
        #expect(progressRecords.count == 1)
        #expect(progressRecords.first?.isPlayed == true)
        #expect(appModel.playback.currentEpisode == nil)
        #expect(lastEpisodePreferences.isEmpty)
    }

    @Test("Played toggles to unplayed through app-model progress semantics")
    func playedToUnplayed() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let episode = makeEpisode(id: "toggle-to-unplayed")
        context.insert(
            EpisodeProgressRecord(
                episodeID: episode.episodeID,
                podcastID: episode.podcastID,
                position: 120,
                duration: 120,
                isPlayed: true
            )
        )
        context.insert(LocalPreferenceRecord(key: "playback.lastEpisodeID", value: episode.episodeID))
        try context.save()
        let appModel = OpenCastAppModel(localLibraryCacheStore: SQLiteLocalLibraryCacheStore.inMemory())
        await appModel.library.load(modelContext: context)
        try appModel.playback.load(appModel.library.domainEpisode(for: episode), startPosition: 120)

        #expect(appModel.toggleEpisodePlayed(episode, modelContext: context))

        let progressRecords = try context.fetch(FetchDescriptor<EpisodeProgressRecord>())
        let lastEpisodePreferences = try context.fetch(FetchDescriptor<LocalPreferenceRecord>())
        #expect(progressRecords.isEmpty)
        #expect(appModel.playback.currentEpisode?.id.rawValue == episode.episodeID)
        #expect(lastEpisodePreferences.isEmpty)
    }

    private func makeEpisode(id: String) -> EpisodeListItemSnapshot {
        EpisodeListItemSnapshot(
            episodeID: id,
            podcastID: "https://example.com/toggle.xml",
            podcastTitle: "Toggle Show",
            title: "Toggle Episode",
            summary: nil,
            publishedAt: .now,
            duration: 120,
            audioURL: "https://example.com/\(id).mp3",
            artworkURL: nil,
            artworkPreview: nil,
            guid: id,
            cachedAt: .now
        )
    }
}
