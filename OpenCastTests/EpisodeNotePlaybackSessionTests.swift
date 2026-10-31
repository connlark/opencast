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
