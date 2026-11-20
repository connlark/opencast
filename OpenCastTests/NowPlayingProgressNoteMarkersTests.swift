import Testing
@testable import OpenCast

@MainActor
@Suite("Note markers on the progress rail")
struct NowPlayingProgressNoteMarkersTests {
    @Test("Endpoints keep their markers; notes outside the timeline and non-finite times are dropped")
    func filtersToTheTimeline() {
        #expect(NowPlayingProgressView.noteMarkers(
            duration: 100,
            timestamps: [0, 25, 100, -1, 101, .nan, .infinity, -.infinity]
        ) == [0, 25, 100])
    }
}
