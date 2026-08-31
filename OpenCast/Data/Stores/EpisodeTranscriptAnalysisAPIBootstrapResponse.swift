import Foundation

/// Response of the account bootstrap route. The account id is server-derived
/// (AppTransaction HMAC) and never stored client-side; decoding it proves
/// the link landed.
nonisolated struct EpisodeTranscriptAnalysisAPIBootstrapResponse: Decodable, Sendable, Equatable {
    var schemaVersion: Int
    var accountID: String
    var balance: EpisodeTranscriptAnalysisAPIBalance

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case accountID = "account_id"
        case balance
    }
}
