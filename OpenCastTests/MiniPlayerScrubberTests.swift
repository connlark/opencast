import Foundation
import Testing
@testable import OpenCast

@Suite("Mini player scrubber")
struct MiniPlayerScrubberTests {
    private typealias Track = MiniPlayerScrubber.Track

    private static func track(position: TimeInterval, duration: TimeInterval?) -> Track {
        var track = Track()
        track.duration = duration
        track.follow(position)
        return track
    }

    @Test("The position follows playback while no drag holds it")
    func followsPlaybackWhileIdle() {
        var track = Self.track(position: 10, duration: 600)
        #expect(track.position == 10)
        track.follow(11)
        track.follow(42.5)
        #expect(track.position == 42.5)
        #expect(!track.isDragging)
    }

    @Test("A drag holds the thumb against playback and seeks once, on release")
    func dragSeeksOnReleaseOnly() {
        var track = Self.track(position: 10, duration: 600)
        track.beginDrag(episodeID: "episode-a")
        track.position = 120
        track.follow(11)
        track.position = 300
        track.follow(12)
        #expect(track.isDragging)
        #expect(track.position == 300, "playback must not move the thumb mid-drag")

        let seek = track.endDrag(currentEpisodeID: "episode-a")
        #expect(seek == 300)
        #expect(!track.isDragging)
        #expect(track.endDrag(currentEpisodeID: "episode-a") == nil, "a second release seeks nothing")

        track.follow(300.4)
        #expect(track.position == 300.4, "after the release playback leads again")
    }

    @Test("A release with no drag in progress seeks nothing")
    func releaseWithoutDrag() {
        var track = Self.track(position: 10, duration: 600)
        #expect(track.endDrag(currentEpisodeID: "episode-a") == nil)
    }

    @Test("A duration change rescales the track and keeps the position inside it")
    func durationChangeRescales() {
        var track = Self.track(position: 300, duration: 600)
        #expect(track.upperBound == 600)
        #expect(track.fraction == 0.5)

        track.duration = 1200
        #expect(track.position == 300)
        #expect(track.fraction == 0.25)

        track.duration = 200
        #expect(track.position == 200)
        #expect(track.fraction == 1)

        track.duration = nil
        #expect(track.upperBound == 200, "an unknown duration falls back to the position")
        track.follow(0)
        #expect(track.upperBound == 1, "and never below one second")
    }

    @Test("A duration change mid-drag keeps the dragged position inside the new range")
    func durationChangeMidDrag() {
        var track = Self.track(position: 10, duration: 600)
        track.beginDrag(episodeID: "episode-a")
        track.position = 500
        track.duration = 400
        #expect(track.position == 400)
        #expect(track.endDrag(currentEpisodeID: "episode-a") == 400)
    }

    @Test("An episode replaced mid-drag ends the drag without seeking the new episode")
    func episodeReplacedMidDrag() {
        var track = Self.track(position: 10, duration: 600)
        track.beginDrag(episodeID: "episode-a")
        track.position = 500

        track.replaceEpisode(position: 12, duration: 900)
        #expect(!track.isDragging)
        #expect(track.position == 12)
        #expect(track.upperBound == 900)
        track.position = 450
        #expect(track.endDrag(currentEpisodeID: "episode-b") == nil)

        track.follow(13)
        #expect(track.position == 13)
    }

    @Test("A release after the episode changed seeks nothing, whichever arrives first")
    func releaseAfterEpisodeChange() {
        var track = Self.track(position: 10, duration: 600)
        track.beginDrag(episodeID: "episode-a")
        track.position = 500
        #expect(track.endDrag(currentEpisodeID: "episode-b") == nil)
        #expect(!track.isDragging)
    }
}
