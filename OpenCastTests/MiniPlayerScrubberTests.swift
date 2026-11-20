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
