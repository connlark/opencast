import Foundation

nonisolated struct EpisodeTranscriptAnalysisUsage: Codable, Sendable, Equatable {
    var promptTokenCount: Int
    var candidatesTokenCount: Int
    var thoughtsTokenCount: Int
    var totalTokenCount: Int
}
