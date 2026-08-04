import Foundation
import OpenCastCore
import SwiftData
import Testing
@testable import OpenCast

@MainActor
struct RemoteTranscriptionStartPreviewRoutingTests {
    @Test("Only the matching episode detail presents a shared preview request")
    func presentationIsScopedToMatchingEpisode() {
        let request = RemoteTranscriptionStartPreviewRequest(
            episodeID: "requested-episode",
            durationSeconds: 900
        )

        #expect(RemoteTranscriptionStartPreviewRouting.presentedRequest(
            request,
            for: "presenting-episode"
        ) == nil)
        #expect(RemoteTranscriptionStartPreviewRouting.presentedRequest(
            request,
            for: "requested-episode"
        ) == request)
    }

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

    @Test("Confirmation surfaces local ownership before starting remote work")
    func confirmationRejectsLocalOwnership() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let appModel = OpenCastAppModel(allowsAutomaticFeedRefresh: false)
        let request = RemoteTranscriptionStartPreviewRequest(
            episodeID: "locally-owned",
            durationSeconds: 900
        )
        context.insert(EpisodeDownloadRecord(
            episodeID: request.episodeID,
            podcastID: "https://example.com/requested.xml",
            sourceAudioURL: "https://example.com/locally-owned.mp3",
            state: .failed,
            episodeTitle: "Locally Owned",
            podcastTitle: "Requested Show"
        ))
        try context.save()
        await appModel.downloads.load(modelContext: context)
        guard case .success(let reservation) = appModel.transcriptions.reserveLocalWork(
            for: request.episodeID
        ) else {
            Issue.record("Expected local ownership to reserve the episode")
            return
        }

        let outcome = appModel.confirmRemoteTranscriptionStart(request, modelContext: context)

        #expect(outcome == .unavailable(
            message: "A local transcription of this episode is already in progress."
        ))
        #expect(appModel.remoteTranscription.store.activeEpisodeID == nil)
        #expect(!appModel.remoteTranscription.store.hasActiveRequest)
        appModel.transcriptions.releaseLocalWork(reservation)
    }

    @Test("Dismissing the shared preview clears it for every mount")
    func dismissalClearsSharedPreview() {
        let store = RemoteTranscriptionJobStore()
        let request = RemoteTranscriptionStartPreviewRequest(
            episodeID: "requested-episode",
            durationSeconds: 900
        )
        store.startPreview = request

        store.dismissStartPreview(ifMatching: request)

        #expect(store.startPreview == nil)
        #expect(RemoteTranscriptionStartPreviewRouting.presentedRequest(
            store.startPreview,
            for: request.episodeID
        ) == nil)
    }
}
