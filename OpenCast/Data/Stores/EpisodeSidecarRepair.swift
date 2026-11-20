import Foundation
import SwiftData

nonisolated enum EpisodeSidecarRepair {
    static func subscribedFeedURLs(modelContext: ModelContext) -> Set<String> {
        let subscriptions = (try? modelContext.fetch(FetchDescriptor<SubscriptionRecord>())) ?? []
        return Set(subscriptions.map(\.feedURL))
    }

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
