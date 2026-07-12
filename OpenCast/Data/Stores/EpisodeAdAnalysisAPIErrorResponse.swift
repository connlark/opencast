import Foundation

nonisolated struct EpisodeAdAnalysisAPIErrorResponse: Decodable, Sendable {
    var error: String
    var detail: String?
}
