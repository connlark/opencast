import Foundation
import OpenCastTranscription
import Testing
@testable import OpenCast

@Suite("Transcript passage index")
struct TranscriptPassageIndexTests {
    @Test("Tokens are folded, stemmed for plurals, and stripped of stop words")
    func tokenizer() {
        #expect(TranscriptPassageTokenizer.tokens(in: "The Café’s Owners were baking pies!") == ["cafe", "owner", "baking", "pie"])
        #expect(TranscriptPassageTokenizer.tokens(in: "um, you know, it's like, yeah") == [])
        #expect(TranscriptPassageTokenizer.tokens(in: "Glasses and buses cross the bridges") == ["glass", "buse", "cross", "bridge"])
        #expect(TranscriptPassageTokenizer.tokens(in: "1994 World Cup") == ["1994", "world", "cup"])
    }

    @Test("Consecutive segments merge until ninety seconds")
    func mergesByDuration() async throws {
        let index = try await TranscriptPassageIndex.build(segments: TranscriptRecapTestFixtures.segments(count: 30, textLength: 30))
        #expect(index.passages.map(\.segmentIDs) == [Array(0...8), Array(9...17), Array(18...26), Array(27...29)])
        #expect(index.passages[0].start == 0)
        #expect(index.passages[0].end == 90)
        #expect(index.passages.map(\.id) == Array(0...3))
    }

    @Test("Consecutive segments merge until a hundred and twenty words")
    func mergesByWordCount() async throws {
        let segments = (0..<6).map { index in
            OpenCastTranscriptSegment(
                id: index,
                start: Double(index),
                end: Double(index + 1),
                text: Array(repeating: "word", count: 50).joined(separator: " "),
                avgLogProbability: -0.1,
                noSpeechProbability: 0.01
            )
        }
        let index = try await TranscriptPassageIndex.build(segments: segments)
        #expect(index.passages.map(\.segmentIDs) == [[0, 1], [2, 3], [4, 5]])
        #expect(index.passages[0].tokenCount == 100)
    }

    @Test("BM25 ranks the passage that matches the query's rare words first")
    func ranksByRelevance() async throws {
        var segments = TranscriptRecapTestFixtures.segments(count: 40, textLength: 30)
        segments[3].text = "We found a needle in the haystack behind the barn."
        segments[22].text = "The haystack was wet after the storm, nothing more."
        segments[31].text = "A needle, a thread, and a very patient tailor."
        let index = try await TranscriptPassageIndex.build(segments: segments)

        let results = index.search("needle haystack", limit: 3)
        #expect(results.first?.segmentIDs.contains(3) == true)
        #expect(results.count == 3)
        #expect(Set(results.flatMap(\.segmentIDs)).isSuperset(of: [3, 22, 31]))

        #expect(index.search("the and of", limit: 3).isEmpty)
        #expect(index.search("zebra", limit: 3).isEmpty)
        #expect(index.search("needle", limit: 0).isEmpty)
        #expect(index.search("NEEDLES", limit: 1).first?.segmentIDs.contains(3) == true)
    }

    @Test("Range lookups return the passages touching the interval in order")
    func rangeLookup() async throws {
        let index = try await TranscriptPassageIndex.build(segments: TranscriptRecapTestFixtures.segments(count: 30, textLength: 30))
        #expect(index.passages(overlapping: 85...95).map(\.id) == [0, 1])
        #expect(index.passages(overlapping: 100...110).map(\.id) == [1])
        #expect(index.passages(overlapping: 400...500).isEmpty)
    }

    @Test("An empty transcript builds an empty index")
    func emptyTranscript() async throws {
        let index = try await TranscriptPassageIndex.build(segments: [])
        #expect(index.passages.isEmpty)
        #expect(index.search("anything", limit: 3).isEmpty)
    }
}
