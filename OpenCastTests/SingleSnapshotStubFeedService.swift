import Foundation
import OpenCastCore
@testable import OpenCast

/// Serves one fixed snapshot per feed URL and refuses every other fetch, so
/// migration and identity tests can move a show between two addresses
/// without a network.
actor SingleSnapshotStubFeedService: FeedService {
    private let snapshotsByURL: [String: FeedSnapshot]

    init(snapshotsByURL: [String: FeedSnapshot]) {
        self.snapshotsByURL = snapshotsByURL
    }

    func fetchFeed(at url: URL) async throws -> FeedSnapshot {
        guard let snapshot = snapshotsByURL[url.absoluteString] else {
            throw CancellationError()
        }
        return snapshot
    }
}
