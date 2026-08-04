import Foundation
import OpenCastTranscription
import Testing
@testable import OpenCast

@Suite("Transcript search index")
struct TranscriptSearchIndexTests {
    @Test("Matches are case and diacritic insensitive")
    func matchesAreCaseAndDiacriticInsensitive() async throws {
        let index = try await TranscriptSearchIndex.build(segments: [
            segment(id: 0, text: "Café culture in Vienna"),
            segment(id: 1, text: "Nothing relevant here"),
            segment(id: 2, text: "the CAFE debate")
        ])

        let result = try await index.result(for: "cafe")

        #expect(result.matchSegmentIDs == [0, 2])
        #expect(result.highlightRangesBySegmentID.keys.sorted() == [0, 2])
    }

    @Test("Blank queries match nothing")
    func blankQueriesMatchNothing() async throws {
        let index = try await TranscriptSearchIndex.build(segments: [segment(id: 0, text: "Some text")])

        #expect(try await index.result(for: "").matchSegmentIDs.isEmpty)
        #expect(try await index.result(for: "   ").matchSegmentIDs.isEmpty)
    }

    @Test("Query whitespace is trimmed before matching")
    func queryWhitespaceIsTrimmedBeforeMatching() async throws {
        let index = try await TranscriptSearchIndex.build(segments: [segment(id: 0, text: "trimmed query")])

        #expect(try await index.result(for: " query \n").matchSegmentIDs == [0])
    }

    @Test("Highlight ranges point into the original text")
    func highlightRangesPointIntoTheOriginalText() async throws {
        let text = "the theme and the anthem"
        let index = try await TranscriptSearchIndex.build(segments: [segment(id: 7, text: text)])

        let result = try await index.result(for: "the")

        let ranges = try #require(result.highlightRangesBySegmentID[7])
        #expect(ranges.map { String(text[$0]) } == ["the", "the", "the", "the"])
    }

    @Test("Match IDs use segment identity, not array position")
    func matchIDsUseSegmentIdentity() async throws {
        let index = try await TranscriptSearchIndex.build(segments: [
            segment(id: 40, text: "nothing"),
            segment(id: 41, text: "needle in a haystack")
        ])

        #expect(try await index.result(for: "needle").matchSegmentIDs == [41])
    }

    @Test("Index work observes cancellation after entering its production loops")
    func asyncIndexWorkPropagatesInFlightCancellation() async throws {
        let segments = (0..<256).map { id in
            segment(id: id, text: "Transcript segment \(id) with a searchable needle")
        }
        let buildGate = TranscriptSearchCheckpointGate(checkpoint: 64)

        let buildTask = Task {
            try await TranscriptSearchIndex.build(segments: segments) { offset in
                await buildGate.reach(offset)
            }
        }
        await buildGate.waitUntilReached()
        buildTask.cancel()
        await buildGate.release()

        await #expect(throws: CancellationError.self) {
            try await buildTask.value
        }

        let index = try await TranscriptSearchIndex.build(segments: segments)
        let queryGate = TranscriptSearchCheckpointGate(checkpoint: 64)
        let queryTask = Task {
            try await index.result(for: "needle") { offset in
                await queryGate.reach(offset)
            }
        }
        await queryGate.waitUntilReached()
        queryTask.cancel()
        await queryGate.release()

        await #expect(throws: CancellationError.self) {
            try await queryTask.value
        }
    }

    @Test("Rapid replacement keeps the newer query authoritative")
    @MainActor
    func rapidQueryReplacementRejectsStaleCompletion() {
        var session = TranscriptSearchSession()
        let olderGeneration = session.begin(query: "older")
        let newerGeneration = session.begin(query: "newer")

        session.finish(generation: olderGeneration)
        #expect(session.isInFlight)
        let acceptedOlderResult = session.publish(
            TranscriptSearchResult(query: "older", matchSegmentIDs: [1]),
            generation: olderGeneration
        )
        let acceptedNewerResult = session.publish(
            TranscriptSearchResult(query: "newer", matchSegmentIDs: [2]),
            generation: newerGeneration
        )
        #expect(!acceptedOlderResult)
        #expect(acceptedNewerResult)
        session.finish(generation: newerGeneration)

        #expect(!session.isInFlight)
        #expect(session.matchSegmentIDs == [2])
    }

    private func segment(id: Int, text: String) -> OpenCastTranscriptSegment {
        OpenCastTranscriptSegment(
            id: id,
            start: TimeInterval(id),
            end: TimeInterval(id + 1),
            text: text,
            avgLogProbability: -0.1,
            noSpeechProbability: 0.01
        )
    }
}

private actor TranscriptSearchCheckpointGate {
    private let checkpoint: Int
    private var reached = false
    private var reachedContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(checkpoint: Int) {
        self.checkpoint = checkpoint
    }

    func reach(_ offset: Int) async {
        guard offset == checkpoint, !reached else {
            return
        }
        reached = true
        reachedContinuation?.resume()
        reachedContinuation = nil
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilReached() async {
        guard !reached else {
            return
        }
        await withCheckedContinuation { continuation in
            reachedContinuation = continuation
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
