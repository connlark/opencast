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
        let session = EpisodeNotePlaybackSession(episodeID: "a", title: "Episode", timestamp: 42, state: state, pause: { pauses += 1 }, playbackIntentRevision: { 0 })
        #expect(pauses == 1)
        #expect(session.draft.timestamp == 42)
        #expect(session.draft.episodeID == "a")
        session.finish(currentEpisodeID: "a", state: .paused, playbackIntentRevision: 0) { plays += 1 }
        #expect(plays == 1)
    }

    @Test("Already paused or failed playback is never restarted", arguments: [PlaybackState.paused, .idle, .failed("Failure")])
    func inactivePlayback(state: PlaybackState) {
        var pauses = 0
        var plays = 0
        let session = EpisodeNotePlaybackSession(episodeID: "a", title: "Episode", timestamp: 42, state: state, pause: { pauses += 1 }, playbackIntentRevision: { 0 })
        session.finish(currentEpisodeID: "a", state: .paused, playbackIntentRevision: 0) { plays += 1 }
        #expect(pauses == 0)
        #expect(plays == 0)
    }

    @Test("Dismissal never plays a different, unloaded or already active episode")
    func changedPlayback() {
        let session = EpisodeNotePlaybackSession(episodeID: "a", title: "Episode", timestamp: 42, state: .playing, pause: {}, playbackIntentRevision: { 0 })
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
        try controller.load(Episode(
            id: EpisodeID(rawValue: "note-episode"),
            podcastID: PodcastID(rawValue: "https://example.com/notes.xml"),
            podcastTitle: "Notes Show",
            title: "Notes Episode",
            duration: 240,
            audioURL: URL(string: "https://example.com/notes.mp3")
        ))
        controller.play()
        #expect(controller.state.showsPauseButton)
        let session = EpisodeNotePlaybackSession(
            episodeID: "note-episode", title: "Notes Episode", timestamp: controller.position,
            state: controller.state, pause: controller.pause,
            playbackIntentRevision: { controller.playbackIntentRevision }
        )
        #expect(controller.state == .paused)
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
            episodeID: "a", title: "Episode", timestamp: 42, state: .playing,
            pause: { revision += 1 }, playbackIntentRevision: { revision }
        )
        #expect(session.playbackIntentRevision == 11)
        if superseded { revision += 1 }
        session.finish(currentEpisodeID: "a", state: .paused, playbackIntentRevision: revision) { plays += 1 }
        #expect(plays == (superseded ? 0 : 1))
    }

}
