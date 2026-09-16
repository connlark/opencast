import Foundation
import OpenCastTranscription
import Testing
@testable import OpenCast

@MainActor
@Suite("Transcript Ask session")
struct TranscriptAskSessionTests {
    private let client = ScriptedTranscriptIntelligenceClient()
    private let store: TranscriptIntelligenceStore
    private let document = TranscriptRecapTestFixtures.document(segments: TranscriptRecapTestFixtures.segments(count: 240))

    init() {
        store = TranscriptIntelligenceStore(client: client, isFeatureEnabled: true, isAskEnabled: true)
        store.refreshAvailability()
    }

    private func makeSession(inputTokenBudget: Int = TranscriptAskSession.sessionInputTokenBudget) async throws -> TranscriptAskSession {
        let index = try await TranscriptPassageIndex.build(segments: document.segments)
        return TranscriptAskSession(store: store, document: document, index: index, inputTokenBudget: inputTokenBudget)
    }

    private static func exchange(showing ids: ClosedRange<Int>) -> TranscriptIntelligenceToolExchange {
        let lines = ids.map { "[#\($0) 0:00–0:10] Segment \($0)" }.joined(separator: "\n")
        return TranscriptIntelligenceToolExchange(
            toolName: "searchTranscript",
            argumentsJSON: #"{"query": "segment"}"#,
            output: "\(TranscriptIntelligencePrompts.transcriptDataFraming)\n\n\(lines)"
        )
    }

    private static func answerJSON(_ text: String, citing ids: [Int], answerable: Bool = true) -> String {
        #"{"answer":"\#(text)","citations":[\#(ids.map(String.init).joined(separator: ","))],"isAnswerable":\#(answerable)}"#
    }

    @Test("A turn validates citations against the passages the tools showed and streams the answer text")
    func turnValidatesAndStreams() async throws {
        client.turns = [.answer(json: Self.answerJSON("Segment thirty-one says so.", citing: [31, 999, 45, 31]), toolExchanges: [Self.exchange(showing: 30...35)])]
        let session = try await makeSession()
        var turns: [TranscriptAskSession.Turn] = []
        session.onTurn = { turns.append($0) }
        var partials: [String] = []

        let answer = try await session.ask("  What does segment 31 say?  ") { partials.append($0) }

        #expect(answer.text == "Segment thirty-one says so.")
        #expect(answer.isAnswerable)
        #expect(answer.citations == [TranscriptAskCitation(segmentID: 31, start: 310)])
        #expect(answer.droppedCitationCount == 2)
        #expect(answer.isVerified)
        #expect(answer.usage != nil)
        let expectedText = "Segment thirty-one says so."
        #expect(partials == [String(expectedText.prefix(expectedText.count / 2)), expectedText])
        #expect(session.exchanges == [TranscriptAskExchange(question: "What does segment 31 say?", answer: "Segment thirty-one says so.", citationIDs: [31], isAnswerable: true)])
        #expect(session.sessionGeneration == 1)
        #expect(turns.count == 1)
        #expect(turns.first?.validation?.droppedCitationIDs == [999, 45])
        #expect(turns.first?.partialUpdateCount == 2)
        #expect(turns.first?.wasReseeded == false)

        let scripted = try #require(client.sessions.first)
        #expect(scripted.instructions == TranscriptIntelligencePrompts.askInstructions)
        #expect(scripted.toolNames == ["searchTranscript", "transcriptAround"])
        #expect(scripted.prompts == ["Question: What does segment 31 say?"])
    }

    @Test("An answer whose citations all fail validation is unverified; an unanswerable one is not")
    func unverifiedAndUnanswerable() async throws {
        client.turns = [
            .answer(json: Self.answerJSON("Confident but unsupported.", citing: [999]), toolExchanges: [Self.exchange(showing: 1...3)]),
            .answer(json: Self.answerJSON("Not covered.", citing: [], answerable: false), toolExchanges: [Self.exchange(showing: 1...3)])
        ]
        let session = try await makeSession()

        let unverified = try await session.ask("First?") { _ in }
        #expect(unverified.isAnswerable)
        #expect(unverified.citations.isEmpty)
        #expect(!unverified.isVerified)
        #expect(unverified.droppedCitationCount == 1)

        let unanswerable = try await session.ask("Second?") { _ in }
        #expect(!unanswerable.isAnswerable)
        #expect(unanswerable.isVerified)
        #expect(client.sessions.count == 1)
    }

    @Test("Past the input budget a fresh session is seeded with the earlier questions and answers, never the tool output")
    func reseeding() async throws {
        client.inputTokensPerPrompt = { _ in 12_000 }
        client.turns = [
            .answer(json: Self.answerJSON("Answer one.", citing: [10]), toolExchanges: [Self.exchange(showing: 10...12)]),
            .answer(json: Self.answerJSON("Answer two.", citing: [20]), toolExchanges: [Self.exchange(showing: 20...22)]),
            .answer(json: Self.answerJSON("Answer three.", citing: [30]), toolExchanges: [Self.exchange(showing: 30...32)])
        ]
        let session = try await makeSession(inputTokenBudget: 20_000)
        var turns: [TranscriptAskSession.Turn] = []
        session.onTurn = { turns.append($0) }

        // 12K after the first turn is under the budget, 24K after the second
        // is not: the third question opens a fresh, seeded session.
        _ = try await session.ask("Question one?") { _ in }
        _ = try await session.ask("Question two?") { _ in }
        #expect(client.sessions.count == 1)
        #expect(session.sessionGeneration == 1)

        _ = try await session.ask("Question three?") { _ in }
        #expect(client.sessions.count == 2)
        #expect(session.sessionGeneration == 2)
        #expect(turns.map(\.wasReseeded) == [false, false, true])
        #expect(turns.map(\.sessionGeneration) == [1, 1, 2])
        let reseeded = try #require(client.sessions.last?.prompts.first)
        #expect(reseeded.hasPrefix("Earlier in this conversation"))
        #expect(reseeded.contains("Q: Question one?\nA: Answer one. [#10]"))
        #expect(reseeded.contains("Q: Question two?\nA: Answer two. [#20]"))
        #expect(reseeded.hasSuffix("Question: Question three?"))
        #expect(!reseeded.contains("[#10 0:00"))
        #expect(!reseeded.contains(TranscriptIntelligencePrompts.transcriptDataFraming))
        #expect(client.sessions.last?.instructions == TranscriptIntelligencePrompts.askInstructions)
        #expect(client.sessions.first?.prompts == ["Question: Question one?", "Question: Question two?"])
        #expect(session.exchanges.count == 3)
    }

    @Test("A guardrail decline keeps the session; a timeout replaces it with a seeded one")
    func failuresAndSessionLifetime() async throws {
        client.turns = [
            .answer(json: Self.answerJSON("Fine.", citing: [5]), toolExchanges: [Self.exchange(showing: 5...5)]),
            .failure(.guardrailViolation),
            .answer(json: Self.answerJSON("Still fine.", citing: [6]), toolExchanges: [Self.exchange(showing: 6...6)]),
            .failure(.timeout),
            .answer(json: Self.answerJSON("Fresh.", citing: [7]), toolExchanges: [Self.exchange(showing: 7...7)])
        ]
        let session = try await makeSession()
        var turns: [TranscriptAskSession.Turn] = []
        session.onTurn = { turns.append($0) }

        _ = try await session.ask("One?") { _ in }
        await #expect(throws: TranscriptIntelligenceFailure.guardrailViolation) {
            _ = try await session.ask("Two?") { _ in }
        }
        _ = try await session.ask("Three?") { _ in }
        #expect(client.sessions.count == 1)
        #expect(session.exchanges.map(\.question) == ["One?", "Three?"])
        #expect(store.availability == .available)

        await #expect(throws: TranscriptIntelligenceFailure.timeout) {
            _ = try await session.ask("Four?") { _ in }
        }
        _ = try await session.ask("Five?") { _ in }
        #expect(client.sessions.count == 2)
        #expect(session.sessionGeneration == 2)
        let seeded = try #require(client.sessions.last?.prompts.first)
        #expect(seeded.contains("Q: One?\nA: Fine. [#5]"))
        #expect(seeded.contains("Q: Three?\nA: Still fine. [#6]"))
        #expect(!seeded.contains("Two?"))
        #expect(turns.compactMap(\.failure) == [.guardrailViolation, .timeout])
    }

    @Test("A follow-up may cite passages shown earlier in the same model session, but not across a reseed")
    func citationsAcrossTurns() async throws {
        client.inputTokensPerPrompt = { _ in 5 }
        client.turns = [
            .answer(json: Self.answerJSON("First.", citing: [31]), toolExchanges: [Self.exchange(showing: 30...35)]),
            .answer(json: Self.answerJSON("Follow-up from memory.", citing: [32, 33]), toolExchanges: []),
            .answer(json: Self.answerJSON("After the reseed.", citing: [34]), toolExchanges: [])
        ]
        let session = try await makeSession(inputTokenBudget: 10)
        var turns: [TranscriptAskSession.Turn] = []
        session.onTurn = { turns.append($0) }

        _ = try await session.ask("One?") { _ in }
        let followUp = try await session.ask("Two?") { _ in }
        #expect(followUp.isVerified)
        #expect(followUp.citations.map(\.segmentID) == [32, 33])
        #expect(followUp.droppedCitationCount == 0)
        #expect(turns.map(\.validatedAgainstSegmentCount) == [6, 6])

        let afterReseed = try await session.ask("Three?") { _ in }
        #expect(turns.last?.wasReseeded == true)
        #expect(!afterReseed.isVerified)
        #expect(afterReseed.citations.isEmpty)
        #expect(afterReseed.droppedCitationCount == 1)
        #expect(turns.last?.validatedAgainstSegmentCount == 0)
    }

    @Test("Inline citation markers come out of the answer text and chips are ordered by time")
    func displayCleanup() async throws {
        client.turns = [.answer(
            json: Self.answerJSON("Second (#40) then first [#20, #21] and a range [#22 3:40–3:50] .", citing: [40, 20, 22]),
            toolExchanges: [Self.exchange(showing: 20...22), Self.exchange(showing: 40...41)]
        )]
        let session = try await makeSession()

        let answer = try await session.ask("Order?") { _ in }
        #expect(answer.text == "Second then first and a range.")
        #expect(answer.citations.map(\.segmentID) == [20, 22, 40])
        #expect(session.exchanges.first?.answer == "Second then first and a range.")
        #expect(session.exchanges.first?.citationIDs == [40, 20, 22])
        #expect(TranscriptAnswerText.strippingCitationMarkers("Plain answer.") == "Plain answer.")
        #expect(TranscriptAnswerText.strippingCitationMarkers("Ends with [#5].") == "Ends with.")
    }

    @Test("Malformed output surfaces as a failure and is not recorded as an exchange")
    func malformedOutput() async throws {
        client.turns = [.json("not json")]
        let session = try await makeSession()
        await #expect(throws: TranscriptIntelligenceFailure.malformedOutput) {
            _ = try await session.ask("Anything?") { _ in }
        }
        #expect(session.exchanges.isEmpty)
        #expect(store.lastFailure == .malformedOutput)
    }
}
