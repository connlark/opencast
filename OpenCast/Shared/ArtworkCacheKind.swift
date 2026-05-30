import Foundation

nonisolated enum ArtworkCacheKind: Sendable {
    case show
    case episode

    var timeToLive: TimeInterval {
        switch self {
        case .show:
            30 * 24 * 60 * 60
        case .episode:
            14 * 24 * 60 * 60
        }
    }
}
