#if DEBUG || INTERNAL_NOTIFICATIONS_DIAGNOSTICS
import Foundation
import Observation

@Observable
final class RemoteEpisodeNotificationRouteDiagnostics {
    static let shared = RemoteEpisodeNotificationRouteDiagnostics()

    private(set) var eventCount = 0
    private(set) var status = "Not Received"
    private(set) var feedURL: String?
    private(set) var canonicalFeedURL: String?
    private(set) var episodeID: String?
    private(set) var episodeTitle: String?
    private(set) var updatedAt: Date?

    private init() {}

    func record(
        _ status: String,
        route: RemoteEpisodeNotificationRoute? = nil,
        canonicalFeedURL: String? = nil
    ) {
        eventCount += 1
        self.status = status
        if let route {
            feedURL = route.feedURL
            episodeID = route.episodeID
            episodeTitle = route.episodeTitle
        }
        if let canonicalFeedURL {
            self.canonicalFeedURL = canonicalFeedURL
        }
        updatedAt = .now
    }
}
#endif
