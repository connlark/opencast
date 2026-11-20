import Foundation

nonisolated enum EpisodeAdAnalysisSpanKind: String, Codable, CaseIterable, Sendable {
    case hostReadAd = "host_read_ad"
    case insertedAd = "inserted_ad"
    case houseOrNetworkPromo = "house_or_network_promo"
    case unknown

    /// An unknown kind decodes as `.unknown` rather than failing the decode; a response carrying
    /// one is untrustworthy and is never skipped on.
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
