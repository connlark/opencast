import FoundationModels

/// `searchTranscript`: the lexical retrieval tool behind Ask. Returns the
/// most relevant passages as segment lines, most relevant first, inside the
/// per-call token budget, and the stop instruction once the turn's call
/// allowance is spent.
nonisolated final class TranscriptPassagesTool: Tool {
    typealias Arguments = TranscriptPassagesToolArguments

    static let defaultPassageLimit = 8

    let name = "searchTranscript"
    let description = """
        Finds the transcript passages most relevant to a few search words. Returns lines as \
        [#segmentID start–end] text, most relevant passage first. Call it before answering.
        """

    private let index: TranscriptPassageIndex
    private let budget: TranscriptToolBudget
    private let passageLimit: Int
    private let tokenBudget: Int
    private let tokenCount: @Sendable (String) async throws -> Int

    init(
        index: TranscriptPassageIndex,
        budget: TranscriptToolBudget,
        passageLimit: Int = defaultPassageLimit,
        tokenBudget: Int = TranscriptToolOutput.defaultTokenBudget,
        tokenCount: @escaping @Sendable (String) async throws -> Int
    ) {
        self.index = index
        self.budget = budget
        self.passageLimit = passageLimit
        self.tokenBudget = tokenBudget
        self.tokenCount = tokenCount
    }

    @concurrent
    func call(arguments: Arguments) async throws -> String {
        guard budget.beginCall() else {
            return TranscriptToolBudget.stopMessage
        }
        let passages = index.search(arguments.query, limit: passageLimit)
        guard !passages.isEmpty else {
            return TranscriptToolOutput.noMatchesMessage
        }
        return try await TranscriptToolOutput.render(
            blocks: passages.map(\.segments),
            tokenBudget: tokenBudget,
            tokenCount: tokenCount
        ).text
    }
}
