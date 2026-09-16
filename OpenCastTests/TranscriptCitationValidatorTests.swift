import Foundation
import OpenCastTranscription
import FoundationModels
import Testing
@testable import OpenCast

@Suite("Transcript citation validator")
struct TranscriptCitationValidatorTests {
    @Test("Citations resolve to the window's segments; unknown ids and blank bullets are dropped in place")
    func validation() throws {
        let segments = TranscriptRecapTestFixtures.segments(count: 20)
        let window = TranscriptRecapWindow(
            kind: .lastFiveMinutes,
            playhead: 150,
            segments: Array(segments[5...14]),
            promptText: "",
            tokenCount: 0,
            isTruncated: false
        )
        let recap = try TranscriptRecap(GeneratedContent(json: """
            {"bullets":[
              {"text":"First point.","segmentID":5},
              {"text":"Outside the window.","segmentID":15},
              {"text":"   ","segmentID":7},
              {"text":" Last point. ","segmentID":14},
              {"text":"Never shown.","segmentID":999},
              {"text":"first point.","segmentID":6}
            ]}
            """))

        let validation = TranscriptCitationValidator.validate(recap, window: window)

        #expect(validation.bullets == [
            TranscriptRecapResultBullet(text: "First point.", segmentID: 5, start: 50),
            TranscriptRecapResultBullet(text: "Last point.", segmentID: 14, start: 140)
        ])
        #expect(validation.droppedCount == 4)
        #expect(validation.droppedBullets.map(\.segmentID) == [15, 7, 999, 6])
    }
}

@Suite("Transcript answer citation validator")
struct TranscriptAnswerCitationValidatorTests {
    @Test("Answer citations resolve only to segments the tools showed this turn")
    func answerValidation() throws {
        let document = TranscriptRecapTestFixtures.document(segments: TranscriptRecapTestFixtures.segments(count: 20))
        let shown = TranscriptIntelligenceToolExchange(
            toolName: "searchTranscript",
            argumentsJSON: #"{"query": "topic"}"#,
            output: """
                \(TranscriptIntelligencePrompts.transcriptDataFraming)

                [#5 0:50–1:00] Segment 5
                [#6 1:00–1:10] Segment 6
                [#7 1:10–1:20] Segment 7
                """
        )
        let unanswered = TranscriptIntelligenceToolExchange(toolName: "transcriptAround", argumentsJSON: "{}", output: nil)
        let answer = try TranscriptAnswer(GeneratedContent(json: #"{"answer":"Yes.","citations":[5,7,8,5,999],"isAnswerable":true}"#))

        #expect(TranscriptCitationValidator.shownSegmentIDs(in: [shown, unanswered]) == [5, 6, 7])
        let validation = TranscriptCitationValidator.validate(answer, toolExchanges: [shown, unanswered], document: document)
        #expect(validation.citations == [
            TranscriptAskCitation(segmentID: 5, start: 50),
            TranscriptAskCitation(segmentID: 7, start: 70)
        ])
        #expect(validation.droppedCitationIDs == [8, 999])

        let nothingShown = TranscriptCitationValidator.validate(answer, toolExchanges: [unanswered], document: document)
        #expect(nothingShown.citations.isEmpty)
        #expect(nothingShown.droppedCitationIDs == [5, 7, 8, 999])
    }
}
