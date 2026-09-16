import Foundation
import OpenCastTranscription
import Testing
@testable import OpenCast

/// Retrieval recall over the frozen evaluation corpus: for every answerable
/// Ask case in the generated evaluation inputs, the passages the search tool
/// would return must include one containing an expected supporting segment.
/// The transcripts live outside the tree, so the suite runs only where
/// `TranscriptEvaluationCorpus` finds the inputs.
@Suite("Transcript passage index on the evaluation corpus", .enabled(if: TranscriptEvaluationCorpus.isAvailable))
struct TranscriptPassageIndexCorpusTests {

    @Test("Every answerable evaluation question retrieves a passage containing an expected segment")
    func recall() async throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let casesURL = try #require(TranscriptEvaluationCorpus.casesURL)
        let cases = try decoder.decode(Cases.self, from: Data(contentsOf: casesURL))
        var indexes: [String: TranscriptPassageIndex] = [:]
        var misses: [String] = []
        var checked = 0
        for question in cases.cases where question.operation == "ask" && question.answerable == true {
            let index = try await Self.index(for: question.fixture, cache: &indexes)
            let text = question.question ?? ""
            let expected = Set(question.expectedSegmentIDs ?? [])
            let results = index.search(text, limit: TranscriptPassagesTool.defaultPassageLimit)
            checked += 1
            if !results.contains(where: { !expected.isDisjoint(with: $0.segmentIDs) }) {
                let ranges = results.map { "\($0.firstSegmentID)–\($0.lastSegmentID)" }.joined(separator: ", ")
                misses.append("\(question.fixture): \"\(text)\" expected \(expected.sorted()), got [\(ranges)]")
            }
        }
        #expect(checked >= 30)
        #expect(misses.isEmpty, Comment(rawValue: misses.joined(separator: "\n")))
    }

    private static func index(
        for fixture: String,
        cache: inout [String: TranscriptPassageIndex]
    ) async throws -> TranscriptPassageIndex {
        if let index = cache[fixture] {
            return index
        }
        let url = try #require(TranscriptEvaluationCorpus.fixtureURL(named: fixture))
        let fixtureFile = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let segments = fixtureFile.segments.map { segment in
            OpenCastTranscriptSegment(
                id: segment.id,
                start: segment.start,
                end: segment.end,
                text: segment.text,
                avgLogProbability: -0.1,
                noSpeechProbability: 0.01
            )
        }
        let index = try await TranscriptPassageIndex.build(segments: segments)
        cache[fixture] = index
        return index
    }

    private struct Cases: Decodable {
        var cases: [Case]
    }

    private struct Case: Decodable {
        var fixture: String
        var operation: String?
        var question: String?
        var answerable: Bool?
        var expectedSegmentIDs: [Int]?

        private enum CodingKeys: String, CodingKey {
            case fixture, operation, question, answerable
            case expectedSegmentIDs = "expectedSegmentIds"
        }
    }

    private struct Fixture: Decodable {
        var segments: [Segment]
    }

    private struct Segment: Decodable {
        var id: Int
        var start: TimeInterval
        var end: TimeInterval
        var text: String
    }
}
