import Foundation

final class EpisodeTranscriptionWorkCoordinator {
    struct LocalReservation: Equatable {
        fileprivate let id = UUID()
        let episodeID: String
    }

    struct RemoteReservation: Equatable {
        fileprivate let id = UUID()
        let episodeID: String
    }

    enum Conflict: Error, Equatable, LocalizedError {
        case anotherLocalTranscription
        case localTranscriptionForEpisode
        case anotherRemoteTranscription
        case remoteTranscriptionForEpisode

        var errorDescription: String? {
            switch self {
            case .anotherLocalTranscription:
                "Another transcription is in progress."
            case .localTranscriptionForEpisode:
                "A local transcription of this episode is already in progress."
            case .anotherRemoteTranscription:
                "Another remote transcription is in progress."
            case .remoteTranscriptionForEpisode:
                "A remote transcription of this episode is already in progress."
            }
        }
    }

    private var localReservationEpisodeID: String?
    private var localReservationIDs: Set<UUID> = []
    private var remoteReservation: RemoteReservation?

    func reserveLocal(episodeID: String) -> Result<LocalReservation, Conflict> {
        if remoteReservation?.episodeID == episodeID {
            return .failure(.remoteTranscriptionForEpisode)
        }
        if localReservationEpisodeID != nil {
            return .failure(.anotherLocalTranscription)
        }

        let reservation = LocalReservation(episodeID: episodeID)
        localReservationEpisodeID = episodeID
        localReservationIDs.insert(reservation.id)
        return .success(reservation)
    }

    func joinLocal(episodeID: String) -> Result<LocalReservation, Conflict> {
        if remoteReservation?.episodeID == episodeID {
            return .failure(.remoteTranscriptionForEpisode)
        }
        if let localReservationEpisodeID, localReservationEpisodeID != episodeID {
            return .failure(.anotherLocalTranscription)
        }

        let reservation = LocalReservation(episodeID: episodeID)
        localReservationEpisodeID = episodeID
        localReservationIDs.insert(reservation.id)
        return .success(reservation)
    }

    func releaseLocal(_ reservation: LocalReservation) {
        guard localReservationEpisodeID == reservation.episodeID,
              localReservationIDs.remove(reservation.id) != nil
        else {
            return
        }
        if localReservationIDs.isEmpty {
            localReservationEpisodeID = nil
        }
    }

    func localStartConflict(
        episodeID: String,
        reservation: LocalReservation?
    ) -> Conflict? {
        if remoteReservation?.episodeID == episodeID {
            return .remoteTranscriptionForEpisode
        }
        if localReservationEpisodeID != nil,
           reservation.map({ localReservationIDs.contains($0.id) }) != true {
            return .anotherLocalTranscription
        }
        return nil
    }

    func reserveRemote(
        episodeID: String,
        activeLocalEpisodeID: String?
    ) -> Result<RemoteReservation, Conflict> {
        if remoteReservation != nil {
            return .failure(.anotherRemoteTranscription)
        }
        if localReservationEpisodeID == episodeID || activeLocalEpisodeID == episodeID {
            return .failure(.localTranscriptionForEpisode)
        }

        let reservation = RemoteReservation(episodeID: episodeID)
        remoteReservation = reservation
        return .success(reservation)
    }

    func releaseRemote(_ reservation: RemoteReservation) {
        guard remoteReservation == reservation else {
            return
        }
        remoteReservation = nil
    }
}
