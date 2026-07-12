import Foundation

nonisolated struct EpisodeAdAnalysisUsage: Codable, Sendable, Equatable {
    var promptTokenCount: Int
    var candidatesTokenCount: Int
    var totalTokenCount: Int
}
