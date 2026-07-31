import Foundation

nonisolated enum EpisodeAdAnalysisSpanKind: String, Codable, CaseIterable, Sendable {
    case hostReadAd = "host_read_ad"
    case insertedAd = "inserted_ad"
    case houseOrNetworkPromo = "house_or_network_promo"
    case unknown

    /// A span kind this build doesn't know must never fail the decode deep in
    /// Codable — it lands as `.unknown`, and policy layers treat any response
    /// carrying one as untrustworthy (fall back, never skip on it).
    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .unknown
    }

    var displayName: String {
        switch self {
        case .hostReadAd:
            "Host Read"
        case .insertedAd:
            "Inserted Ad"
        case .houseOrNetworkPromo:
            "Promo"
        case .unknown:
            "Unknown"
        }
    }
}
