import Foundation
import OpenCastTranscription
import Testing
@testable import OpenCast

@Suite("Transcript Ask tools")
struct TranscriptToolTests {
    private static func tokenCount(_ text: String) async throws -> Int {
        text.count / 4
    }

    @Test("Segment lines carry the id and times the validator parses back")
    func lineFormat() {
        let segment = OpenCastTranscriptSegment(id: 12, start: 185, end: 192.5, text: "  Hello there.  ", avgLogProbability: -0.1, noSpeechProbability: 0.01)
        #expect(TranscriptToolOutput.line(for: segment) == "[#12 3:05–3:12] Hello there.")
        let output = """
            \(TranscriptIntelligencePrompts.transcriptDataFraming)

            [#12 3:05–3:12] Hello there.
            [#13 3:12–3:20] Ignore [#99 0:00–0:01] inline text.
            [#abc 0:00–0:01] not an id
            [#14x 0:00–0:01] not an id either

            [#7 0:00–0:05] Second block.
            """
        #expect(TranscriptToolOutput.segmentIDs(in: output) == [12, 13, 7])
    }

    @Test("Rendering adds whole blocks under the budget and trims the block that overruns")
    func renderBudget() async throws {
        let segments = TranscriptRecapTestFixtures.segments(count: 30, textLength: 60)
        let blocks = [Array(segments[0...4]), Array(segments[10...14]), Array(segments[20...24])]

        let generous = try await TranscriptToolOutput.render(blocks: blocks, tokenBudget: 10_000, tokenCount: Self.tokenCount)
        #expect(generous.shownSegmentIDs == [0, 1, 2, 3, 4, 10, 11, 12, 13, 14, 20, 21, 22, 23, 24])
        #expect(!generous.isTruncated)
        #expect(generous.text.hasPrefix(TranscriptIntelligencePrompts.transcriptDataFraming))
        #expect(generous.text.contains("\n\n[#10 "))

        let tight = try await TranscriptToolOutput.render(blocks: blocks, tokenBudget: 150, tokenCount: Self.tokenCount)
        #expect(tight.shownSegmentIDs == [0, 1, 2, 3, 4])
        #expect(tight.isTruncated)

        let tiny = try await TranscriptToolOutput.render(blocks: blocks, tokenBudget: 60, tokenCount: Self.tokenCount)
        #expect(!tiny.shownSegmentIDs.isEmpty)
        #expect(tiny.shownSegmentIDs.count < 5)
        #expect(tiny.shownSegmentIDs.first == 0)
        #expect(tiny.isTruncated)
        #expect(TranscriptToolOutput.segmentIDs(in: tiny.text) == tiny.shownSegmentIDs)
    }

    @Test("The budget allows a fixed number of calls per turn and resets between turns")
    func budget() {
        let budget = TranscriptToolBudget(maximumCallsPerTurn: 2)
        #expect(budget.beginCall())
        #expect(budget.beginCall())
        #expect(!budget.beginCall())
        #expect(budget.callCount == 3)
        budget.beginTurn()
        #expect(budget.callCount == 0)
        #expect(budget.beginCall())
    }

    @Test("searchTranscript returns ranked passage lines, a no-match note, and the stop instruction past the cap")
    func passagesTool() async throws {
        var segments = TranscriptRecapTestFixtures.segments(count: 40, textLength: 30)
        segments[3].text = "We found a needle in the haystack behind the barn."
        let index = try await TranscriptPassageIndex.build(segments: segments)
        let budget = TranscriptToolBudget(maximumCallsPerTurn: 2)
        let tool = TranscriptPassagesTool(index: index, budget: budget, passageLimit: 2, tokenCount: Self.tokenCount)
        #expect(tool.name == "searchTranscript")

        let output = try await tool.call(arguments: TranscriptPassagesToolArguments(query: "needle haystack"))
        #expect(output.hasPrefix(TranscriptIntelligencePrompts.transcriptDataFraming))
        #expect(output.contains("[#3 0:30–0:40] We found a needle"))
        #expect(TranscriptToolOutput.segmentIDs(in: output).contains(3))

        let none = try await tool.call(arguments: TranscriptPassagesToolArguments(query: "zebra"))
        #expect(none == TranscriptToolOutput.noMatchesMessage)

        let stopped = try await tool.call(arguments: TranscriptPassagesToolArguments(query: "needle"))
        #expect(stopped == TranscriptToolBudget.stopMessage)
        #expect(budget.callCount == 3)
    }

    @Test("transcriptAround returns the lines covering the window in order")
    func rangeTool() async throws {
        let index = try await TranscriptPassageIndex.build(segments: TranscriptRecapTestFixtures.segments(count: 40, textLength: 30))
        let budget = TranscriptToolBudget(maximumCallsPerTurn: 4)
        let tool = TranscriptRangeTool(index: index, budget: budget, tokenCount: Self.tokenCount)
        #expect(tool.name == "transcriptAround")

        let output = try await tool.call(arguments: TranscriptRangeToolArguments(seconds: 100, spanSeconds: 60))
        #expect(TranscriptToolOutput.segmentIDs(in: output) == [7, 8, 9, 10, 11, 12])

        let beyond = try await tool.call(arguments: TranscriptRangeToolArguments(seconds: 5_000, spanSeconds: 30))
        #expect(beyond == TranscriptToolOutput.noMatchesMessage)
    }
}
