import Foundation

/// Payload of `POST /v1/transcript-analysis/account/bootstrap` (App Attest
/// envelope only). The AppTransaction JWS is required by purchase-backend
/// lanes and ignored by the development fake, so it rides along whenever the
/// shared cache can produce one.
nonisolated struct EpisodeTranscriptAnalysisAPIBootstrapRequest: Encodable, Sendable, Equatable {
    var schemaVersion: Int
    var appTransactionJWS: String?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case appTransactionJWS = "app_transaction_jws"
    }
}
