import Foundation
import OpenCastCore
import SwiftData
import Testing
@testable import OpenCast

@MainActor
struct RemoteTranscriptionStartPreviewRoutingTests {
    @Test("Confirmation starts the request episode when Now Playing has changed")
    func confirmationUsesRequestEpisode() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let request = RemoteTranscriptionStartPreviewRequest(
            episodeID: "charged-episode",
            durationSeconds: 900
        )
        let appModel = OpenCastAppModel(allowsAutomaticFeedRefresh: false)
        context.insert(EpisodeDownloadRecord(
            episodeID: request.episodeID,
            podcastID: "https://example.com/requested.xml",
            sourceAudioURL: "",
            state: .failed,
            episodeTitle: "Requested Episode",
            podcastTitle: "Requested Show"
        ))
        try context.save()
        await appModel.downloads.load(modelContext: context)
        try appModel.playback.load(Episode(
            id: EpisodeID(rawValue: "presenting-episode"),
            podcastID: PodcastID(rawValue: "https://example.com/presenting.xml"),
            podcastTitle: "Presenting Show",
            title: "Presenting Episode",
            duration: 120,
            audioURL: URL(string: "https://example.com/presenting.mp3")
        ))

        let outcome = appModel.confirmRemoteTranscriptionStart(request, modelContext: context)

        #expect(outcome == .started(episodeID: request.episodeID))
        #expect(appModel.playback.currentEpisode?.id.rawValue == "presenting-episode")
        #expect(appModel.remoteTranscription.store.activeEpisodeID == request.episodeID)
        #expect(appModel.remoteTranscription.store.phase(for: request.episodeID) != nil)
    }

    @Test("A missing request episode produces a visible failure outcome and no job")
    func missingRequestEpisodeFailsWithoutStartingJob() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let appModel = OpenCastAppModel(allowsAutomaticFeedRefresh: false)
        let request = RemoteTranscriptionStartPreviewRequest(
            episodeID: "missing-episode",
            durationSeconds: 900
        )

        let outcome = appModel.confirmRemoteTranscriptionStart(request, modelContext: context)

        guard case .unavailable(let message) = outcome else {
            Issue.record("Expected a missing-episode confirmation failure.")
            return
        }
        #expect(message.contains("no longer available"))
        #expect(appModel.remoteTranscription.store.activeEpisodeID == nil)
        #expect(!appModel.remoteTranscription.store.hasActiveRequest)
    }
}
