import Foundation

nonisolated struct EpisodeTranscriptAnalysisAPIUsage: Codable, Sendable, Equatable {
    var promptTokenCount: Int
    var candidatesTokenCount: Int
    /// Thinking tokens bill as output alongside candidates; recorded so the
    /// uncharged alpha's real per-run cost can price the at-cost minutes rate.
    var thoughtsTokenCount: Int
    var totalTokenCount: Int

    enum CodingKeys: String, CodingKey {
        case promptTokenCount = "prompt_token_count"
        case candidatesTokenCount = "candidates_token_count"
        case thoughtsTokenCount = "thoughts_token_count"
        case totalTokenCount = "total_token_count"
    }

    init(
        promptTokenCount: Int,
        candidatesTokenCount: Int,
        thoughtsTokenCount: Int = 0,
        totalTokenCount: Int
    ) {
        self.promptTokenCount = promptTokenCount
        self.candidatesTokenCount = candidatesTokenCount
        self.thoughtsTokenCount = thoughtsTokenCount
        self.totalTokenCount = totalTokenCount
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        promptTokenCount = try container.decode(Int.self, forKey: .promptTokenCount)
        candidatesTokenCount = try container.decode(Int.self, forKey: .candidatesTokenCount)
        thoughtsTokenCount = try container.decodeIfPresent(Int.self, forKey: .thoughtsTokenCount) ?? 0
        totalTokenCount = try container.decode(Int.self, forKey: .totalTokenCount)
    }
}
