import Foundation

nonisolated enum FeedTransportErrorClassifier {
    /// Only codes URLSession returns without touching the wire. `.timedOut`, `.cannotFindHost` and the
    /// like stay ordinary failures: a dead feed host returns them on a healthy network.
    static func isUnreachable(_ error: any Error) -> Bool {
        guard let urlError = error as? URLError else {
            return false
        }
        return switch urlError.code {
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
            true
        default:
            false
        }
    }
}
