import Testing
@testable import OpenCast

@MainActor
@Suite("Note timeline markers")
struct NowPlayingNoteMarkersTests {
    @Test("Markers include endpoints and omit notes outside the current timeline")
    func positions() {
        #expect(NowPlayingNoteMarkers.fractions(
            duration: 100,
            timestamps: [0, 25, 100, -1, 101, .nan, .infinity]
        ) == [0, 0.25, 1])
    }

    @Test("Unknown or invalid duration hides markers rather than placing them against elapsed time")
    func unknownDuration() {
        let durations: [Double?] = [nil, 0, -1, .nan, .infinity]
        for duration in durations {
            #expect(NowPlayingNoteMarkers.fractions(duration: duration, timestamps: [10]).isEmpty)
        }
    }
}
