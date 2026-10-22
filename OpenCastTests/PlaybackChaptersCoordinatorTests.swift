import Foundation
import OpenCastCore
import Testing
@testable import OpenCast

@MainActor
@Suite("PlaybackChaptersCoordinator", .serialized)
struct PlaybackChaptersCoordinatorTests {
    @Test("Chapters follow the player item: a source switch and an unload clear the list")
    func followsPlayerItem() async throws {
        let fixture = try await OpenCastSystemActionFixture.make()
        let model = fixture.model
        let episode = Episode(
            id: EpisodeID(rawValue: "chaptered"),
            podcastID: PodcastID(rawValue: OpenCastSystemActionFixture.feed),
            podcastTitle: "A Show",
            title: "Chaptered",
            duration: 3,
            audioURL: Self.fixture("ChapteredSilence.mp3")
        )
        try model.playback.load(episode)
        model.refreshPlaybackSkipZonesForCurrentEpisode()
        #expect(await Self.waitUntil { model.currentEpisodeChapters.chapters.count == 3 })
        #expect(model.currentEpisodeChapters.source == .embedded)

        // The controller rebuilds its item on its own for a download switch
        // (and for a failed-item recovery); no app-model refresh follows.
        #expect(model.playback.useDownloadedAudio(at: Self.fixture("UntaggedSilence.mp3"), for: episode.id))
        #expect(await Self.waitUntil { model.currentEpisodeChapters.isEmpty })
        // The clear above is immediate; the untagged file's read must settle
        // empty too, so a late read of the old item cannot repopulate it.
        await model.waitForChapterRefresh()
        #expect(model.currentEpisodeChapters.isEmpty)

        try model.playback.load(episode)
        #expect(await Self.waitUntil { model.currentEpisodeChapters.chapters.count == 3 })

        model.playback.unload()
        #expect(await Self.waitUntil { model.currentEpisodeChapters.isEmpty })
    }

    private static func fixture(_ name: String) -> URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Packages/OpenCastPlayback/Tests/OpenCastPlaybackTests/Fixtures/\(name)")
    }

    private static func waitUntil(
        timeout: Duration = .seconds(10),
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }
}
