import FoundationModels
import OpenCastTranscription

/// `transcriptAround`: the segments covering a time range, in order, for
/// questions that name a moment in the episode or follow up on a citation.
nonisolated final class TranscriptRangeTool: Tool {
    typealias Arguments = TranscriptRangeToolArguments

    let name = "transcriptAround"
    let description = """
        Returns the transcript lines around a moment in the episode, in order, as \
        [#segmentID start–end] text. Use it when the question names a time or refers to an earlier citation.
        """

    private let index: TranscriptPassageIndex
    private let budget: TranscriptToolBudget
    private let tokenBudget: Int
    private let tokenCount: @Sendable (String) async throws -> Int

    init(
        index: TranscriptPassageIndex,
        budget: TranscriptToolBudget,
        tokenBudget: Int = TranscriptToolOutput.defaultTokenBudget,
        tokenCount: @escaping @Sendable (String) async throws -> Int
    ) {
        self.index = index
        self.budget = budget
        self.tokenBudget = tokenBudget
        self.tokenCount = tokenCount
    }

    @concurrent
    func call(arguments: Arguments) async throws -> String {
        guard budget.beginCall() else {
            return TranscriptToolBudget.stopMessage
        }
        let center = Double(max(arguments.seconds, 0))
        let half = Double(min(max(arguments.spanSeconds, 30), 300)) / 2
        let range = max(0, center - half)...(center + half)
        let segments = index.passages(overlapping: range)
            .flatMap(\.segments)
            .filter { $0.start < range.upperBound && $0.end > range.lowerBound }
        guard !segments.isEmpty else {
            return TranscriptToolOutput.noMatchesMessage
        }
        return try await TranscriptToolOutput.render(
            blocks: [segments],
            tokenBudget: tokenBudget,
            tokenCount: tokenCount
        ).text
    }
}
