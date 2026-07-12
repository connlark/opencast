import Foundation

nonisolated enum EpisodeAdAnalysisSpanKind: String, Codable, CaseIterable, Sendable {
    case hostReadAd = "host_read_ad"
    case insertedAd = "inserted_ad"
    case houseOrNetworkPromo = "house_or_network_promo"

    var displayName: String {
        switch self {
        case .hostReadAd:
            "Host Read"
        case .insertedAd:
            "Inserted Ad"
        case .houseOrNetworkPromo:
            "Promo"
        }
    }
}
