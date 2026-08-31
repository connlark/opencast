import Foundation

nonisolated struct EpisodeTranscriptAnalysisAPIClaim: Codable, Sendable, Equatable {
    var text: String
    var evidenceSegmentID: Int

    enum CodingKeys: String, CodingKey {
        case text
        case evidenceSegmentID = "evidence_segment_id"
    }
}
