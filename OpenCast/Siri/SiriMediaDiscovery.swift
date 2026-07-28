import Intents
import os

final class SiriMediaDiscovery {
    nonisolated private static let logger = Logger(
        subsystem: "com.connor.opencast",
        category: "SiriMedia"
    )

    private let userContextPublisher: @MainActor (Int) -> Void
    private let interactionDonator: @MainActor (INInteraction) -> Void
    private let interactionGroupDeleter: @MainActor (String) -> Void
    private var lastDonatedPodcastID: String?

    init(
        userContextPublisher: @escaping @MainActor (Int) -> Void = SiriMediaDiscovery.publishUserContext,
        interactionDonator: @escaping @MainActor (INInteraction) -> Void = SiriMediaDiscovery.donateInteraction,
        interactionGroupDeleter: @escaping @MainActor (String) -> Void = SiriMediaDiscovery.deleteInteractionGroup
    ) {
        self.userContextPublisher = userContextPublisher
        self.interactionDonator = interactionDonator
        self.interactionGroupDeleter = interactionGroupDeleter
    }

    func publishUserContext(subscriptionCount: Int) {
        userContextPublisher(subscriptionCount)
    }

    func donatePlaybackIfNeeded(for episode: EpisodeListItemSnapshot) {
        guard lastDonatedPodcastID != episode.podcastID else {
            return
        }

        lastDonatedPodcastID = episode.podcastID
        interactionDonator(SiriDonationBuilder.interaction(for: episode))
    }

    func deleteDonations(forPodcastID podcastID: String) {
        if lastDonatedPodcastID == podcastID {
            lastDonatedPodcastID = nil
        }
        interactionGroupDeleter(podcastID)
    }

    func deleteDonations(forPodcastIDs podcastIDs: Set<String>) {
        for podcastID in podcastIDs {
            deleteDonations(forPodcastID: podcastID)
        }
    }

    private static func publishUserContext(subscriptionCount: Int) {
        let context = INMediaUserContext()
        context.numberOfLibraryItems = subscriptionCount
        context.becomeCurrent()
    }

    private static func donateInteraction(_ interaction: INInteraction) {
        interaction.donate { error in
            if let error {
                Self.logger.error(
                    "Siri media interaction donation failed: \(error.localizedDescription, privacy: .private)"
                )
            }
        }
    }

    private static func deleteInteractionGroup(_ groupIdentifier: String) {
        INInteraction.delete(with: groupIdentifier) { error in
            if let error {
                Self.logger.error(
                    "Siri media interaction-group deletion failed: \(error.localizedDescription, privacy: .private)"
                )
            }
        }
    }
}
