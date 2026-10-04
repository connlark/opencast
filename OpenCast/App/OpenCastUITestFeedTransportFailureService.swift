import Foundation
import OpenCastCore

/// UI-test seam: every feed fetch fails with one transport error, so a test
/// can drive a refresh the way a device without a network sees it.
nonisolated struct OpenCastUITestFeedTransportFailureService: FeedService {
    static let environmentKey = "OPENCAST_UI_TEST_FEED_TRANSPORT_FAILURE"

    let code: URLError.Code

    static func resolve(environment: [String: String]) -> URLError.Code? {
        guard let rawValue = environment[environmentKey]?.trimmedNonEmpty else {
            return nil
        }

        return switch rawValue {
        case "notConnectedToInternet":
            .notConnectedToInternet
        case "dataNotAllowed":
            .dataNotAllowed
        case "internationalRoamingOff":
            .internationalRoamingOff
        case "networkConnectionLost":
            .networkConnectionLost
        case "timedOut":
            .timedOut
        default:
            nil
        }
    }

    func prepareFeed(
        at url: URL,
        validators: FeedValidators?,
        intent: FeedPreparationIntent
    ) async throws -> PreparedFeedOutcome {
        throw URLError(code)
    }

    func prepareFeed(at url: URL, validators: FeedValidators?) async throws -> PreparedFeedOutcome {
        throw URLError(code)
    }

    func fetchFeed(at url: URL) async throws -> FeedSnapshot {
        throw URLError(code)
    }
}
