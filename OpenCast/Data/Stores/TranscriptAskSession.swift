import Foundation
import FoundationModels

/// One Ask conversation over one transcript: the model session, its two
/// retrieval tools, the per-turn call budget, and the in-memory history. A
/// turn runs one streamed structured request under the store's deadline and
/// validates its citations against the passages the tools have shown in the
/// current model session (a follow-up often answers from passages fetched
/// a turn earlier without calling a tool again). The model session is
/// replaced once its input passes the budget, seeded with the earlier
/// questions and answers but none of their passages, and after any failure
/// that leaves it unusable; a guardrail decline keeps it, so the
/// conversation continues.
final class TranscriptAskSession {
    static let sessionInputTokenBudget = 20_000
    static let maximumResponseTokens = 600
    static let maximumToolCallsPerTurn = 4
    static let historySeedExchangeLimit = 8
    static let historySeedTokenBudget = 2_000

    /// Everything one turn produced, for the evaluation runner's report.
    struct Turn: Sendable {
        var question: String
        var prompt: String
        var answer: TranscriptAnswer?
        var validation: TranscriptAskValidation?
        var failure: TranscriptIntelligenceFailure?
        var toolExchanges: [TranscriptIntelligenceToolExchange] = []
        var toolCallCount = 0
        var usage: TranscriptIntelligenceUsage?
        var latency: TimeInterval
        var sessionGeneration: Int
        var wasReseeded: Bool
        var sessionInputTokenCount: Int
        var partialUpdateCount = 0
        /// Segment ids citations were validated against: every id the tools
        /// have shown in the current model session.
        var validatedAgainstSegmentCount = 0
    }

    private(set) var exchanges: [TranscriptAskExchange] = []
    private(set) var sessionGeneration = 0
    var onTurn: ((Turn) -> Void)?

    private let store: TranscriptIntelligenceStore
    private let document: EpisodeTranscriptDocument
    private let tools: [any Tool]
    private let budget: TranscriptToolBudget
    private var session: (any TranscriptIntelligenceSession)?
    private var shownSegmentIDsInSession: Set<Int> = []
    private var inputTokenBudget: Int

    init(
        store: TranscriptIntelligenceStore,
        document: EpisodeTranscriptDocument,
        index: TranscriptPassageIndex,
        inputTokenBudget: Int = sessionInputTokenBudget
    ) {
        self.store = store
        self.document = document
        self.inputTokenBudget = inputTokenBudget
        let budget = TranscriptToolBudget(maximumCallsPerTurn: Self.maximumToolCallsPerTurn)
        let tokenCount: @Sendable (String) async throws -> Int = { text in
            try await store.tokenCount(for: text)
        }
        self.budget = budget
        tools = [
            TranscriptPassagesTool(index: index, budget: budget, tokenCount: tokenCount),
            TranscriptRangeTool(index: index, budget: budget, tokenCount: tokenCount)
        ]
    }

    func ask(
        _ question: String,
        onPartialAnswer: @escaping @MainActor (String) -> Void
    ) async throws -> TranscriptAskAnswer {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let (session, wasReseeded) = await currentSession()
        let prompt = wasReseeded
            ? TranscriptIntelligencePrompts.askPrompt(question: question, history: await seedHistory())
            : TranscriptIntelligencePrompts.askPrompt(question: question)
        budget.beginTurn()
        var turn = Turn(
            question: question,
            prompt: prompt,
            latency: 0,
            sessionGeneration: sessionGeneration,
            wasReseeded: wasReseeded,
            sessionInputTokenCount: session.inputTokenCount
        )
        let clock = ContinuousClock()
        let started = clock.now
        let partialUpdates = TranscriptAskPartialUpdateCounter()
        let response: TranscriptIntelligenceResponse<TranscriptAnswer>
        do {
            response = try await store.perform {
                try await session.respond(
                    to: prompt,
                    generating: TranscriptAnswer.self,
                    options: TranscriptIntelligenceGenerationOptions(
                        maximumResponseTokens: Self.maximumResponseTokens,
                        toolCalling: .allowed
                    )
                ) { content in
                    partialUpdates.increment()
                    if let text = try? content.value(String.self, forProperty: "answer"), !text.isEmpty {
                        onPartialAnswer(text)
                    }
                }
            }
        } catch {
            let failure = error as? TranscriptIntelligenceFailure ?? .failure(mapping: error)
            if Self.invalidatesSession(failure) {
                self.session = nil
            }
            turn.failure = failure
            turn.toolCallCount = budget.callCount
            turn.latency = Self.seconds(clock.now - started)
            turn.sessionInputTokenCount = session.inputTokenCount
            turn.partialUpdateCount = partialUpdates.count
            onTurn?(turn)
            throw error
        }
        shownSegmentIDsInSession.formUnion(TranscriptCitationValidator.shownSegmentIDs(in: response.toolExchanges))
        let validation = TranscriptCitationValidator.validate(
            response.content,
            shownSegmentIDs: shownSegmentIDsInSession,
            document: document
        )
        let latency = Self.seconds(clock.now - started)
        let text = TranscriptAnswerText.strippingCitationMarkers(response.content.answer)
        exchanges.append(TranscriptAskExchange(
            question: question,
            answer: text,
            citationIDs: validation.citations.map(\.segmentID),
            isAnswerable: response.content.isAnswerable
        ))
        turn.answer = response.content
        turn.validation = validation
        turn.toolExchanges = response.toolExchanges
        turn.toolCallCount = budget.callCount
        turn.usage = response.usage
        turn.latency = latency
        turn.sessionInputTokenCount = session.inputTokenCount
        turn.partialUpdateCount = partialUpdates.count
        turn.validatedAgainstSegmentCount = shownSegmentIDsInSession.count
        onTurn?(turn)
        return TranscriptAskAnswer(
            text: text,
            isAnswerable: response.content.isAnswerable,
            citations: validation.citations.sorted { $0.start < $1.start },
            droppedCitationCount: validation.droppedCitationIDs.count,
            toolCallCount: budget.callCount,
            usage: response.usage,
            latency: latency
        )
    }

    /// The live session, or a fresh one when none exists or the last has
    /// grown past the input budget. The second value says whether history
    /// must be replayed into it.
    private func currentSession() async -> (any TranscriptIntelligenceSession, wasReseeded: Bool) {
        if let session, session.inputTokenCount < inputTokenBudget {
            return (session, false)
        }
        let fresh = store.makeSession(instructions: TranscriptIntelligencePrompts.askInstructions, tools: tools)
        session = fresh
        shownSegmentIDsInSession = []
        sessionGeneration += 1
        return (fresh, !exchanges.isEmpty)
    }

    /// The most recent exchanges that fit the seed budget, oldest first.
    private func seedHistory() async -> [TranscriptAskExchange] {
        var history = Array(exchanges.suffix(Self.historySeedExchangeLimit))
        while history.count > 1 {
            let count = try? await store.tokenCount(for: TranscriptIntelligencePrompts.askHistoryPreamble(history))
            guard let count, count > Self.historySeedTokenBudget else {
                break
            }
            history.removeFirst()
        }
        return history
    }

    /// A declined or refused prompt leaves the session usable; a timeout
    /// (our deadline cancelled the model mid-turn), a full context, or an
    /// unknown failure does not.
    private static func invalidatesSession(_ failure: TranscriptIntelligenceFailure) -> Bool {
        switch failure {
        case .guardrailViolation, .refusal, .cancelled:
            false
        case .rateLimited, .quotaLimitReached, .contextSizeExceeded, .notEntitled, .offline,
             .serviceUnavailable, .timeout, .unsupportedLanguage, .malformedOutput, .unknown:
            true
        }
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
