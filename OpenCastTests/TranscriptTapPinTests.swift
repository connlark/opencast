import Foundation
import OpenCastTranscription
import Testing
@testable import OpenCast

@Suite("Transcript tap pin")
struct TranscriptTapPinTests {
    private var pin: TranscriptTapPin {
        TranscriptTapPin(
            segment: OpenCastTranscriptSegment(
                id: 12,
                start: 120.0,
                end: 126.0,
                text: "Pinned line",
                avgLogProbability: -0.1,
                noSpeechProbability: 0.01
            ),
            segmentIndex: 12
        )
    }

    @Test("Holds while the seek lands fractionally before the segment")
    func holdsWhileTheSeekLandsFractionallyBeforeTheSegment() {
        #expect(!pin.shouldRelease(computedSegmentIndex: 11, position: 119.9))
        #expect(!pin.shouldRelease(computedSegmentIndex: nil, position: 119.5))
    }

    @Test("Releases once playback reaches the pinned segment")
    func releasesOncePlaybackReachesThePinnedSegment() {
        #expect(pin.shouldRelease(computedSegmentIndex: 12, position: 120.0))
        #expect(pin.shouldRelease(computedSegmentIndex: 13, position: 130.0))
    }

    @Test("Releases when the user seeks well before the pinned segment")
    func releasesWhenTheUserSeeksWellBeforeThePinnedSegment() {
        #expect(pin.shouldRelease(computedSegmentIndex: 4, position: 60.0))
    }
}
