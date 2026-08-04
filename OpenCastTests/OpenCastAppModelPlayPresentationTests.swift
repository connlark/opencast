import Foundation
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("App model play presentation")
struct OpenCastAppModelPlayPresentationTests {
    @Test("Play requests the phone Now Playing presentation unless the caller opts out")
    func presentsNowPlayingOnlyWhenRequested() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let appModel = OpenCastAppModel(
            localLibraryCacheStore: SQLiteLocalLibraryCacheStore.inMemory(),
            allowsAutomaticFeedRefresh: false
        )
        let silent = makeEpisode(episodeID: "play-presentation-silent")
        let presenting = makeEpisode(episodeID: "play-presentation-default")

        // The CarPlay path: a car tap must never queue a phone sheet.
        try appModel.playEpisode(silent, presentsNowPlaying: false, modelContext: context)
        #expect(appModel.playback.currentEpisode?.id.rawValue == silent.episodeID)
        for _ in 0..<10 {
            await Task.yield()
        }
        #expect(appModel.nowPlayingPresentationRequest == 0)

        try appModel.playEpisode(presenting, modelContext: context)
        #expect(await waitUntil { appModel.nowPlayingPresentationRequest == 1 })
    }

    private func makeEpisode(episodeID: String) -> EpisodeListItemSnapshot {
        .fixture(
            episodeID: episodeID,
            title: "Example Episode \(episodeID)",
            audioURL: "https://example.com/\(episodeID).mp3",
            guid: episodeID
        )
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
