import Foundation

/// Balance snapshot on billing responses: the shared transcription-seconds
/// account that analysis debits at the flat rate (decision H7).
nonisolated struct EpisodeTranscriptAnalysisAPIBalance: Decodable, Sendable, Equatable {
    var availableSeconds: Int64
    var reservedSeconds: Int64
    var debtSeconds: Int64

    enum CodingKeys: String, CodingKey {
        case availableSeconds = "available_seconds"
        case reservedSeconds = "reserved_seconds"
        case debtSeconds = "debt_seconds"
    }
}
