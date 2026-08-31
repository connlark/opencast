import Foundation

nonisolated struct EpisodeTranscriptAnalysisAPIErrorResponse: Decodable, Sendable {
    var error: String
    var detail: String?
}
