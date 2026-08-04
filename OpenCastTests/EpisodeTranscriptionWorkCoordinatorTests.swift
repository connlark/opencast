import Testing
@testable import OpenCast

@MainActor
@Suite("Episode transcription work coordination")
struct EpisodeTranscriptionWorkCoordinatorTests {
    @Test("Same-episode local and remote work is mutually exclusive in both directions")
    func sameEpisodeWorkIsMutuallyExclusive() {
        let localFirst = EpisodeTranscriptionWorkCoordinator()
        guard case .success(let localReservation) = localFirst.reserveLocal(episodeID: "episode") else {
            Issue.record("Expected the local reservation to succeed")
            return
        }
        #expect(localFirst.reserveRemote(
            episodeID: "episode",
            activeLocalEpisodeID: nil
        ) == .failure(.localTranscriptionForEpisode))
        localFirst.releaseLocal(localReservation)

        let remoteFirst = EpisodeTranscriptionWorkCoordinator()
        guard case .success(let remoteReservation) = remoteFirst.reserveRemote(
            episodeID: "episode",
            activeLocalEpisodeID: nil
        ) else {
            Issue.record("Expected the remote reservation to succeed")
            return
        }
        #expect(remoteFirst.reserveLocal(episodeID: "episode")
            == .failure(.remoteTranscriptionForEpisode))
        remoteFirst.releaseRemote(remoteReservation)
    }

    @Test("Different-episode local and remote work remains allowed")
    func differentEpisodeWorkIsAllowed() {
        let coordinator = EpisodeTranscriptionWorkCoordinator()
        guard case .success(let localReservation) = coordinator.reserveLocal(episodeID: "local") else {
            Issue.record("Expected the local reservation to succeed")
            return
        }
        guard case .success(let remoteReservation) = coordinator.reserveRemote(
            episodeID: "remote",
            activeLocalEpisodeID: "local"
        ) else {
            Issue.record("Expected different-episode remote work to succeed")
            return
        }

        coordinator.releaseRemote(remoteReservation)
        coordinator.releaseLocal(localReservation)
    }

    @Test("Same-episode attachments keep the original local reservation alive")
    func sameEpisodeAttachmentsUseIndependentLeases() {
        let coordinator = EpisodeTranscriptionWorkCoordinator()
        guard case .success(let owner) = coordinator.reserveLocal(episodeID: "episode"),
              case .success(let attachment) = coordinator.joinLocal(episodeID: "episode")
        else {
            Issue.record("Expected both same-episode local leases to succeed")
            return
        }

        coordinator.releaseLocal(attachment)
        #expect(coordinator.reserveRemote(
            episodeID: "episode",
            activeLocalEpisodeID: nil
        ) == .failure(.localTranscriptionForEpisode))

        coordinator.releaseLocal(owner)
        guard case .success(let remote) = coordinator.reserveRemote(
            episodeID: "episode",
            activeLocalEpisodeID: nil
        ) else {
            Issue.record("Expected remote work after every local lease released")
            return
        }
        coordinator.releaseRemote(remote)
    }
}
