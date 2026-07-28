import Intents
import Testing
@testable import OpenCast

@MainActor
@Suite("Siri media discovery")
struct SiriMediaDiscoveryTests {
    @Test("Repeated playback donations are deduplicated per show")
    func repeatedShowDonationIsDeduplicated() {
        let recorder = SiriMediaDiscoveryRecorder()
        let discovery = makeDiscovery(recorder: recorder)

        discovery.donatePlaybackIfNeeded(for: episode(id: "one", podcastID: "show-a"))
        discovery.donatePlaybackIfNeeded(for: episode(id: "two", podcastID: "show-a"))

        #expect(recorder.donatedGroupIdentifiers == ["show-a"])
    }

    @Test("Playback changing shows creates a new donation")
    func showChangeCreatesDonation() {
        let recorder = SiriMediaDiscoveryRecorder()
        let discovery = makeDiscovery(recorder: recorder)

        discovery.donatePlaybackIfNeeded(for: episode(id: "one", podcastID: "show-a"))
        discovery.donatePlaybackIfNeeded(for: episode(id: "two", podcastID: "show-b"))

        #expect(recorder.donatedGroupIdentifiers == ["show-a", "show-b"])
    }

    @Test("Deleting a show group resets local donation deduplication")
    func groupDeletionResetsDeduplication() {
        let recorder = SiriMediaDiscoveryRecorder()
        let discovery = makeDiscovery(recorder: recorder)
        let playedEpisode = episode(id: "one", podcastID: "show-a")

        discovery.donatePlaybackIfNeeded(for: playedEpisode)
        discovery.deleteDonations(forPodcastID: "show-a")
        discovery.donatePlaybackIfNeeded(for: playedEpisode)

        #expect(recorder.deletedGroupIdentifiers == ["show-a"])
        #expect(recorder.donatedGroupIdentifiers == ["show-a", "show-a"])
    }

    @Test("Deleting all data removes every donated show group")
    func multiShowDeletion() {
        let recorder = SiriMediaDiscoveryRecorder()
        let discovery = makeDiscovery(recorder: recorder)

        discovery.deleteDonations(forPodcastIDs: ["show-a", "show-b"])

        #expect(Set(recorder.deletedGroupIdentifiers) == ["show-a", "show-b"])
    }

    private func makeDiscovery(recorder: SiriMediaDiscoveryRecorder) -> SiriMediaDiscovery {
        SiriMediaDiscovery(
            userContextPublisher: { recorder.publishedCounts.append($0) },
            interactionDonator: { interaction in
                recorder.donatedGroupIdentifiers.append(interaction.groupIdentifier ?? "")
            },
            interactionGroupDeleter: { recorder.deletedGroupIdentifiers.append($0) }
        )
    }

    private func episode(id: String, podcastID: String) -> EpisodeListItemSnapshot {
        EpisodeListItemSnapshot(
            episodeID: id,
            podcastID: podcastID,
            podcastTitle: "Example Show",
            title: "Episode \(id)",
            summary: nil,
            publishedAt: nil,
            duration: 60,
            audioURL: "https://example.com/\(id).mp3",
            artworkURL: nil,
            artworkPreview: nil,
            guid: id,
            cachedAt: .now
        )
    }
}

@MainActor
private final class SiriMediaDiscoveryRecorder {
    var publishedCounts: [Int] = []
    var donatedGroupIdentifiers: [String] = []
    var deletedGroupIdentifiers: [String] = []
}
