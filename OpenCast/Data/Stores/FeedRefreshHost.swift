import Foundation
import SwiftData

/// What the refresh flows need from the core store: the observable state
/// machine they drive, the subscription reads that pick their feed sets, and
/// the publication that stays with the store.
protocol FeedRefreshHost: AnyObject {
    var state: LibraryStore.State { get set }
    var lastErrorMessage: String? { get set }
    var subscriptions: [SubscriptionRecord] { get }
    var latestRefreshLogByFeedURL: [String: RefreshLogSnapshot] { get }
    var feedURLStringsNeedingLocalCache: [String] { get }
    func activeSubscription(feedURL: String, modelContext: ModelContext) throws -> SubscriptionRecord?
    func activeSubscriptionFeedURLStrings(modelContext: ModelContext) throws -> [String]
    func reloadFromStore(modelContext: ModelContext) async throws
    func reloadRefreshLogsFromStore() async throws
    func recordFailure(_ error: any Error)
}
