import Foundation

nonisolated struct EpisodeAdAnalysisAPIUsage: Codable, Sendable, Equatable {
    var promptTokenCount: Int
    var candidatesTokenCount: Int
    var totalTokenCount: Int

    enum CodingKeys: String, CodingKey {
        case promptTokenCount = "prompt_token_count"
        case candidatesTokenCount = "candidates_token_count"
        case totalTokenCount = "total_token_count"
    }
}
