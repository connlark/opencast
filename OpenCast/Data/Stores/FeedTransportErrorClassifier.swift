import Foundation

nonisolated enum FeedTransportErrorClassifier {
    /// URLSession returns these codes without putting the request on the
    /// wire: no satisfied network path, or a device or carrier policy refused
    /// it. The host-ambiguous codes (`.timedOut`, `.cannotFindHost`,
    /// `.cannotConnectToHost`, `.networkConnectionLost`, …) stay ordinary
    /// failures because a dead feed host returns them on a healthy network,
    /// and that feed must keep its refresh diagnostics.
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
