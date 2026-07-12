#if canImport(CoreMedia) && canImport(Speech)
import CoreMedia
import Foundation
@testable import OpenCastTranscription
import Speech
import Testing

@Suite("Apple Speech transcription adapter")
struct AppleSpeechTranscriptionServiceTests {
    @Test("Mapper preserves Apple Speech audio time range attributes")
    func mapperPreservesAppleSpeechAudioTimeRangeAttributes() throws {
        guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, tvOS 26.0, *) else {
            return
        }

        var text = AttributedString("Hello")
        let helloRange = try #require(text.range(of: "Hello"))
        text[helloRange].audioTimeRange = CMTimeRange(
            start: CMTime(seconds: 3.5, preferredTimescale: 1_000),
            duration: CMTime(seconds: 1.25, preferredTimescale: 1_000)
        )
        text[helloRange].transcriptionConfidence = 0.87

        let segments = AppleSpeechTranscriptionService.mappedSegments(
            from: text,
            fallbackRange: CMTimeRange(
                start: CMTime(seconds: 0, preferredTimescale: 1_000),
                duration: CMTime(seconds: 10, preferredTimescale: 1_000)
            )
        )

        #expect(segments.count == 1)
        #expect(segments.first?.id == 0)
        #expect(segments.first?.text == "Hello")
        #expect(segments.first?.start == 3.5)
        #expect(segments.first?.end == 4.75)
        let avgLogProbability = try #require(segments.first?.avgLogProbability)
        #expect(abs(avgLogProbability - 0.87) < 0.000_001)
        #expect(segments.first?.noSpeechProbability == 0)
    }

    @Test("Mapper falls back to result range when runs have no time attributes")
    func mapperFallsBackToResultRangeWhenRunsHaveNoTimeAttributes() {
        guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, tvOS 26.0, *) else {
            return
        }

        let segments = AppleSpeechTranscriptionService.mappedSegments(
            from: AttributedString("Untimed phrase"),
            fallbackRange: CMTimeRange(
                start: CMTime(seconds: 12, preferredTimescale: 1_000),
                duration: CMTime(seconds: 2.5, preferredTimescale: 1_000)
            )
        )

        #expect(segments.count == 1)
        #expect(segments.first?.text == "Untimed phrase")
        #expect(segments.first?.start == 12)
        #expect(segments.first?.end == 14.5)
    }

    @Test("Coalescer emits phrase-sized segments from Apple word timing")
    func coalescerEmitsPhraseSizedSegmentsFromAppleWordTiming() {
        guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, tvOS 26.0, *) else {
            return
        }

        let segments = AppleSpeechTranscriptionService.coalescedSegments([
            segment(id: 0, start: 0, end: 0.4, text: "Hello"),
            segment(id: 1, start: 0.45, end: 0.85, text: "world."),
            segment(id: 2, start: 1, end: 1.4, text: "Next"),
            segment(id: 3, start: 1.45, end: 1.9, text: "idea")
        ], startingAt: 10)

        #expect(segments.count == 2)
        #expect(segments[0].id == 10)
        #expect(segments[0].start == 0)
        #expect(segments[0].end == 0.85)
        #expect(segments[0].text == "Hello world.")
        #expect(segments[1].id == 11)
        #expect(segments[1].start == 1)
        #expect(segments[1].end == 1.9)
        #expect(segments[1].text == "Next idea")
    }

    @Test("Accumulator keeps finals whose ranges touch with float fuzz")
    func accumulatorKeepsFinalsWhoseRangesTouchWithFloatFuzz() {
        guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, tvOS 26.0, *) else {
            return
        }

        // Real device runs emit adjacent final results whose shared boundary differs
        // by ~1e-14s after CMTime conversion; that fuzz must not evict the earlier final.
        var accumulator = AppleSpeechResultAccumulator()
        accumulator.replaceSegments(
            in: timeRange(start: 85.68, end: 91.38),
            with: [segment(id: 0, start: 85.68, end: 91.38, text: "First sentence.")]
        )
        accumulator.replaceSegments(
            in: timeRange(start: 91.38 - 0.000_000_000_01, end: 98.04),
            with: [segment(id: 0, start: 91.38, end: 98.04, text: "Second sentence.")]
        )

        let segments = accumulator.orderedSegments()
        #expect(segments.map(\.text) == ["First sentence.", "Second sentence."])
        #expect(segments.map(\.id) == [0, 1])
    }

    @Test("Accumulator replaces materially re-finalized ranges")
    func accumulatorReplacesMateriallyReFinalizedRanges() {
        guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, tvOS 26.0, *) else {
            return
        }

        var accumulator = AppleSpeechResultAccumulator()
        accumulator.replaceSegments(
            in: timeRange(start: 10, end: 20),
            with: [segment(id: 0, start: 10, end: 20, text: "Stale hypothesis")]
        )
        accumulator.replaceSegments(
            in: timeRange(start: 12, end: 22),
            with: [segment(id: 0, start: 12, end: 22, text: "Re-finalized text")]
        )

        #expect(accumulator.orderedSegments().map(\.text) == ["Re-finalized text"])
    }

    private func timeRange(start: TimeInterval, end: TimeInterval) -> CMTimeRange {
        CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 1_000_000_000),
            duration: CMTime(seconds: end - start, preferredTimescale: 1_000_000_000)
        )
    }

    @Test("Coalescer splits Apple segments across long pauses")
    func coalescerSplitsAppleSegmentsAcrossLongPauses() {
        guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, tvOS 26.0, *) else {
            return
        }

        let segments = AppleSpeechTranscriptionService.coalescedSegments([
            segment(id: 0, start: 0, end: 0.4, text: "First"),
            segment(id: 1, start: 1.4, end: 1.8, text: "second")
        ])

        #expect(segments.count == 2)
        #expect(segments[0].text == "First")
        #expect(segments[1].text == "second")
    }

    @Test("Event throttle strides by audio time and emits the first event immediately")
    func eventThrottleStridesByAudioTime() {
        var throttle = AppleSpeechEventThrottle()

        let progressEmits = [1, 3, 5.9, 6, 10.9, 11].map {
            throttle.shouldEmitProgress(at: $0)
        }
        #expect(progressEmits == [true, false, false, true, false, true])

        let checkpointEmits = [2, 30, 61.9, 62, 100, 122].map {
            throttle.shouldEmitCheckpoint(at: $0)
        }
        #expect(checkpointEmits == [true, false, false, true, false, true])
    }

    @Test("Progress and checkpoint throttles stride independently")
    func eventThrottleTracksStreamsIndependently() {
        var throttle = AppleSpeechEventThrottle()
        let emitsFirstProgress = throttle.shouldEmitProgress(at: 0)
        let emitsFirstCheckpoint = throttle.shouldEmitCheckpoint(at: 0)
        #expect(emitsFirstProgress)
        #expect(emitsFirstCheckpoint)

        // A dense sentence burst: progress keeps striding at 5 s while
        // checkpoints stay parked until 60 s of audio has accumulated.
        var emittedProgress = 0
        var emittedCheckpoints = 0
        for tenths in stride(from: 5, through: 590, by: 5) {
            let duration = TimeInterval(tenths) / 10
            if throttle.shouldEmitProgress(at: duration) {
                emittedProgress += 1
            }
            if throttle.shouldEmitCheckpoint(at: duration) {
                emittedCheckpoints += 1
            }
        }
        #expect(emittedProgress == 11)
        #expect(emittedCheckpoints == 0)
        let emitsAtSixtySeconds = throttle.shouldEmitCheckpoint(at: 60)
        #expect(emitsAtSixtySeconds)
    }

    @Test("Mapper captures word timings whose joined text reconstructs the segment text")
    func mapperCapturesWordTimingsThatReconstructSegmentText() throws {
        guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, tvOS 26.0, *) else {
            return
        }

        var text = AttributedString("Hello world.")
        let helloRange = try #require(text.range(of: "Hello"))
        text[helloRange].audioTimeRange = timeRange(start: 3.5, end: 4)
        let worldRange = try #require(text.range(of: "world."))
        text[worldRange].audioTimeRange = timeRange(start: 4.25, end: 4.75)

        let segments = AppleSpeechTranscriptionService.mappedSegments(
            from: text,
            fallbackRange: timeRange(start: 0, end: 10)
        )

        #expect(segments.count == 1)
        let segment = try #require(segments.first)
        let words = try #require(segment.words)
        #expect(words.map(\.text) == ["Hello", "world."])
        #expect(words.map(\.start) == [3.5, 4.25])
        #expect(words.map(\.end) == [4, 4.75])
        #expect(joinedWordText(words) == segment.text)
        #expect(words.allSatisfy { $0.start >= segment.start && $0.end <= segment.end })
    }

    @Test("Mapper fallback segment carries no word timings")
    func mapperFallbackSegmentCarriesNoWordTimings() {
        guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, tvOS 26.0, *) else {
            return
        }

        let segments = AppleSpeechTranscriptionService.mappedSegments(
            from: AttributedString("Untimed phrase"),
            fallbackRange: timeRange(start: 12, end: 14.5)
        )

        #expect(segments.count == 1)
        #expect(segments.first?.words == nil)
    }

    @Test("Coalescer concatenates word timings within segment bounds")
    func coalescerConcatenatesWordTimingsWithinSegmentBounds() throws {
        guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, tvOS 26.0, *) else {
            return
        }

        let segments = AppleSpeechTranscriptionService.coalescedSegments([
            segment(id: 0, start: 0, end: 0.4, text: "Hello", words: [word(0, 0.4, "Hello")]),
            segment(id: 1, start: 0.45, end: 0.85, text: "world.", words: [word(0.45, 0.85, "world.")]),
            segment(id: 2, start: 1, end: 1.4, text: "Next", words: [word(1, 1.4, "Next")]),
            segment(id: 3, start: 1.45, end: 1.9, text: "idea", words: [word(1.45, 1.9, "idea")])
        ])

        #expect(segments.count == 2)
        let first = try #require(segments.first)
        let firstWords = try #require(first.words)
        #expect(firstWords.map(\.text) == ["Hello", "world."])
        #expect(firstWords.allSatisfy { $0.start >= first.start && $0.end <= first.end })
        let second = try #require(segments.last)
        let secondWords = try #require(second.words)
        #expect(secondWords.map(\.text) == ["Next", "idea"])
        #expect(secondWords.allSatisfy { $0.start >= second.start && $0.end <= second.end })
    }

    @Test("Coalescer emits nil words for mixed word provenance")
    func coalescerEmitsNilWordsForMixedWordProvenance() {
        guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, tvOS 26.0, *) else {
            return
        }

        let segments = AppleSpeechTranscriptionService.coalescedSegments([
            segment(id: 0, start: 0, end: 0.4, text: "Timed", words: [word(0, 0.4, "Timed")]),
            segment(id: 1, start: 0.45, end: 0.85, text: "untimed")
        ])

        #expect(segments.count == 1)
        #expect(segments.first?.words == nil)
    }

    @Test("Accumulator reindexing preserves word timings")
    func accumulatorReindexingPreservesWordTimings() {
        guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, tvOS 26.0, *) else {
            return
        }

        var accumulator = AppleSpeechResultAccumulator()
        accumulator.replaceSegments(
            in: timeRange(start: 10, end: 20),
            with: [segment(id: 0, start: 10, end: 20, text: "Second", words: [word(10, 20, "Second")])]
        )
        accumulator.replaceSegments(
            in: timeRange(start: 0, end: 10),
            with: [segment(id: 0, start: 0, end: 10, text: "First", words: [word(0, 10, "First")])]
        )

        let segments = accumulator.orderedSegments()
        #expect(segments.map(\.id) == [0, 1])
        #expect(segments.map(\.words) == [[word(0, 10, "First")], [word(10, 20, "Second")]])
    }

    @Test("Segment decodes nil words from JSON without the key and omits nil words on encode")
    func segmentCodableCompatibilityForWords() throws {
        let legacyJSON = Data("""
        {"id":1,"start":0,"end":2,"text":"Hi","avgLogProbability":0.5,"noSpeechProbability":0}
        """.utf8)
        let decoded = try JSONDecoder().decode(OpenCastTranscriptSegment.self, from: legacyJSON)
        #expect(decoded.words == nil)

        let encodedWithoutWords = try JSONEncoder().encode(decoded)
        let withoutWordsJSON = try #require(String(data: encodedWithoutWords, encoding: .utf8))
        #expect(!withoutWordsJSON.contains("\"words\""))

        let worded = segment(id: 1, start: 0, end: 2, text: "Hi", words: [word(0, 2, "Hi")])
        let roundTripped = try JSONDecoder().decode(
            OpenCastTranscriptSegment.self,
            from: JSONEncoder().encode(worded)
        )
        #expect(roundTripped == worded)
    }

    private func word(
        _ start: TimeInterval,
        _ end: TimeInterval,
        _ text: String
    ) -> OpenCastTranscriptWord {
        OpenCastTranscriptWord(start: start, end: end, text: text)
    }

    private func joinedWordText(_ words: [OpenCastTranscriptWord]) -> String {
        let attached = CharacterSet(charactersIn: ".,;:!?)]}%")
        return words.reduce(into: "") { result, word in
            if result.isEmpty || word.text.unicodeScalars.allSatisfy(attached.contains) {
                result += word.text
            } else {
                result += " " + word.text
            }
        }
    }

    private func segment(
        id: Int,
        start: TimeInterval,
        end: TimeInterval,
        text: String,
        words: [OpenCastTranscriptWord]? = nil
    ) -> OpenCastTranscriptSegment {
        OpenCastTranscriptSegment(
            id: id,
            start: start,
            end: end,
            text: text,
            avgLogProbability: 0.8,
            noSpeechProbability: 0,
            words: words
        )
    }
}
#endif
