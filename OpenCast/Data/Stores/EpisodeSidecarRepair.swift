import Foundation
import SwiftData

/// Shared support for collapsing duplicate sidecar record groups. Identity
/// migration collisions can leave several active records under one episode
/// ID; every sidecar store must repair that back to one survivor chosen by
/// artifact proof and stable ordering — never by fetch order.
nonisolated enum EpisodeSidecarRepair {
    static func subscribedFeedURLs(modelContext: ModelContext) -> Set<String> {
        let subscriptions = (try? modelContext.fetch(FetchDescriptor<SubscriptionRecord>())) ?? []
        return Set(subscriptions.map(\.feedURL))
    }

    /// The canonical podcast ID for a repaired group: the first candidate (in
    /// winner-priority order) that is an actively subscribed feed. Divergent
    /// IDs happen when an old feed identity's rows were re-keyed onto a
    /// successor episode without adopting the successor's feed.
    static func preferredPodcastID(
        orderedCandidates: [String],
        subscribedFeedURLs: Set<String>
    ) -> String? {
        orderedCandidates.first { subscribedFeedURLs.contains($0) }
    }

    /// Last-resort ordering key so survivor selection never depends on the
    /// fetch order of otherwise identical rows.
    static func stableOrderingKey(_ model: some PersistentModel) -> String {
        String(describing: model.persistentModelID)
    }
}
