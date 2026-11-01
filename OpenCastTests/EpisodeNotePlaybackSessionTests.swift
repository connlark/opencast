import Foundation
import OpenCastCore
import OpenCastPlayback
import Testing
@testable import OpenCast

@MainActor
@Suite("Note editor playback session")
struct EpisodeNotePlaybackSessionTests {
    @Test("Playing, loading and buffering pause once and resume the captured episode", arguments: [PlaybackState.playing, .loading, .buffering])
    func activePlayback(state: PlaybackState) {
        var pauses = 0
        var plays = 0
        let session = EpisodeNotePlaybackSession(episode: episode(), timestamp: 42, state: state, pause: { pauses += 1 }, playbackIntentRevision: { 0 })
        #expect(pauses == 1)
        #expect(session.draft.timestamp == 42)
        #expect(session.draft.episodeID == "a")
        session.finish(currentEpisodeID: "a", state: .paused, playbackIntentRevision: 0) { plays += 1 }
        #expect(plays == 1)
    }

    @Test("The draft is a timestamped note carrying the playing episode's show, title and artwork", arguments: [PlaybackState.playing, .paused])
    func draftCarriesEpisodeDetails(state: PlaybackState) {
        let session = EpisodeNotePlaybackSession(episode: episode(), timestamp: 42, state: state, pause: {}, playbackIntentRevision: { 0 })
        #expect(session.draft.episodeID == "a")
        #expect(session.draft.podcastID == "https://example.com/show-a.xml")
        #expect(session.draft.podcastTitle == "Show A")
        #expect(session.draft.episodeTitle == "Episode A")
        #expect(session.draft.artworkURL == "https://example.com/a.jpg")
        #expect(session.draft.timestamp == 42)
        #expect(!session.draft.isEpisodeWide)
        #expect(session.draft.noteID == nil)
        #expect(session.draft.initialText.isEmpty)
        #expect(session.draft.resumesPlaybackOnDismiss == (state == .playing))
    }

    @Test("Already paused or failed playback is never restarted", arguments: [PlaybackState.paused, .idle, .failed("Failure")])
    func inactivePlayback(state: PlaybackState) {
        var pauses = 0
        var plays = 0
        let session = EpisodeNotePlaybackSession(episode: episode(), timestamp: 42, state: state, pause: { pauses += 1 }, playbackIntentRevision: { 0 })
        session.finish(currentEpisodeID: "a", state: .paused, playbackIntentRevision: 0) { plays += 1 }
        #expect(pauses == 0)
        #expect(plays == 0)
    }

    @Test("Dismissal never plays a different, unloaded or already active episode")
    func changedPlayback() {
        let session = EpisodeNotePlaybackSession(episode: episode(), timestamp: 42, state: .playing, pause: {}, playbackIntentRevision: { 0 })
        var plays = 0
        session.finish(currentEpisodeID: "b", state: .paused, playbackIntentRevision: 0) { plays += 1 }
        session.finish(currentEpisodeID: nil, state: .paused, playbackIntentRevision: 0) { plays += 1 }
        session.finish(currentEpisodeID: "a", state: .playing, playbackIntentRevision: 0) { plays += 1 }
        session.finish(currentEpisodeID: "a", state: .failed("Failure"), playbackIntentRevision: 0) { plays += 1 }
        #expect(plays == 0)
    }
    @Test(
        "On the real controller a skip or a scrub while the editor is open keeps dismissal from resuming",
        arguments: ["nothing", "skip", "scrub"]
    )
    func realControllerSupersession(command: String) throws {
        let controller = AVFoundationPlaybackController()
        defer { controller.unload() }
        let playing = Episode(
            id: EpisodeID(rawValue: "note-episode"),
            podcastID: PodcastID(rawValue: "https://example.com/notes.xml"),
            podcastTitle: "Notes Show",
            title: "Notes Episode",
            duration: 240,
            audioURL: URL(string: "https://example.com/notes.mp3")
        )
        try controller.load(playing)
        controller.play()
        #expect(controller.state.showsPauseButton)
        let session = EpisodeNotePlaybackSession(
            episode: EpisodeListItemSnapshot(episode: playing), timestamp: controller.position,
            state: controller.state, pause: controller.pause,
            playbackIntentRevision: { controller.playbackIntentRevision }
        )
        #expect(controller.state == .paused)
        #expect(session.draft.episodeID == "note-episode")
        #expect(session.draft.podcastID == "https://example.com/notes.xml")
        #expect(session.draft.podcastTitle == "Notes Show")
        #expect(session.draft.episodeTitle == "Notes Episode")
        switch command {
        case "skip": controller.skip(by: 15)
        case "scrub": controller.seek(to: 10, intent: .scrub)
        default: break
        }
        var plays = 0
        session.finish(
            currentEpisodeID: controller.currentEpisode?.id.rawValue,
            state: controller.state,
            playbackIntentRevision: controller.playbackIntentRevision
        ) { plays += 1 }
        #expect(plays == (command == "nothing" ? 1 : 0))
    }

    @Test("A later playback command supersedes the editor pause even when still paused", arguments: [false, true])
    func pauseOwnership(superseded: Bool) {
        var revision: UInt64 = 10
        var plays = 0
        let session = EpisodeNotePlaybackSession(
            episode: episode(), timestamp: 42, state: .playing,
            pause: { revision += 1 }, playbackIntentRevision: { revision }
        )
        #expect(session.playbackIntentRevision == 11)
        if superseded { revision += 1 }
        session.finish(currentEpisodeID: "a", state: .paused, playbackIntentRevision: revision) { plays += 1 }
        #expect(plays == (superseded ? 0 : 1))
    }

    private func episode() -> EpisodeListItemSnapshot {
        EpisodeListItemSnapshot(
            episodeID: "a",
            podcastID: "https://example.com/show-a.xml",
            podcastTitle: "Show A",
            title: "Episode A",
            summary: nil,
            publishedAt: nil,
            duration: 240,
            audioURL: "https://example.com/a.mp3",
            artworkURL: "https://example.com/a.jpg",
            artworkPreview: nil,
            guid: nil,
            cachedAt: .now
        )
    }
}
