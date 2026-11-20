import Foundation
import OpenCastTranscription
import SwiftData
@testable import OpenCast

/// The minimum recovery regression set for the remote job lanes. Each case
/// is one row of the recovery fixture matrix: its fault script configures a
/// `RemoteJobFaultInjectingAPI`, `seedPersistedState` plants the reference,
/// queue record and server job an earlier process would have left behind,
/// and `clientSeam` names the client-side condition (process death,
/// expiration, user action) the owning test drives through the store,
/// runner or coordinator rather than through the API.
enum RemoteJobRecoveryFixture: String, Sendable {
    case createNeverLeaves
    case createAcceptedResponseLost
    case createDelayedThenUserCancels
    case cancelResponseLost
    case transportAfterAttach
    case localLegFailure
    case deathAfterImport
    case deathAfterAck
    case acknowledgedWithoutImport
    case cloudParked
    case parkedCloudUserCancel
    case ownerBeforeClear

    enum ClientSeam: Equatable, Sendable {
        case userCancelDuringCreate
        case userCancelAfterAttach
        case processDeathAfterImport
        case processDeathAfterAck
        case sessionExpiration
        case userRemovesPendingParkedItem
        case referenceClearedBeforeSummary
    }

    /// What an earlier process left behind, planted by `seedPersistedState`.
    struct PersistedSeed: Sendable {
        let reference: RemoteTranscriptionJobReference
        let jobID: String
        /// Present for cloud fixtures: the pending queue record at the head.
        let queueRecordEpisodeID: String?
    }

    static let seededJobID = "job-seeded-1"

    var clientSeam: ClientSeam? {
        switch self {
        case .createDelayedThenUserCancels: .userCancelDuringCreate
        case .cancelResponseLost: .userCancelAfterAttach
        case .deathAfterImport: .processDeathAfterImport
        case .deathAfterAck: .processDeathAfterAck
        case .cloudParked: .sessionExpiration
        case .parkedCloudUserCancel: .userRemovesPendingParkedItem
        case .ownerBeforeClear: .referenceClearedBeforeSummary
        case .createNeverLeaves, .createAcceptedResponseLost, .transportAfterAttach,
             .localLegFailure, .acknowledgedWithoutImport:
            nil
        }
    }

    /// The purpose whose reference the fixture exercises.
    var purpose: RemoteTranscriptionJobPurpose {
        switch self {
        case .cloudParked, .parkedCloudUserCancel: .adDetection
        default: .transcription
        }
    }

    /// The server state an earlier process left the seeded job in, for
    /// fixtures that start from persisted state.
    var seededServerState: OpenCastRemoteTranscriptionJobState? {
        switch self {
        case .cloudParked, .parkedCloudUserCancel: .transcribing
        case .deathAfterImport: .resultReady
        case .deathAfterAck: .acknowledged
        default: nil
        }
    }

    /// A fresh fake carrying this fixture's fault script. `gate` is consumed
    /// by the delayed-create fixture; other fixtures ignore it.
    func makeAPI(
        gate: RemoteJobFaultInjectingAPI.Gate = RemoteJobFaultInjectingAPI.Gate(),
        resultResponse: OpenCastRemoteTranscriptionResultResponse? = nil
    ) -> RemoteJobFaultInjectingAPI {
        let api = RemoteJobFaultInjectingAPI(
            pollScript: pollScript,
            resultResponse: resultResponse
        )
        switch self {
        case .createNeverLeaves:
            api.inject(.neverLeaves(URLError(.cannotConnectToHost)), at: .create)
        case .createAcceptedResponseLost:
            api.inject(.acceptedResponseLost(URLError(.networkConnectionLost)), at: .create)
        case .createDelayedThenUserCancels:
            api.inject(.delayed(gate), at: .create)
        case .cancelResponseLost:
            api.inject(.acceptedResponseLost(URLError(.networkConnectionLost)), at: .cancel)
        case .transportAfterAttach:
            api.inject(.neverLeaves(URLError(.notConnectedToInternet)), at: .poll, times: .max)
        case .localLegFailure:
            api.inject(.localFailure(AppAttestKeychainError(status: -25300)), at: .poll, times: .max)
        case .deathAfterImport, .deathAfterAck, .acknowledgedWithoutImport,
             .cloudParked, .parkedCloudUserCancel, .ownerBeforeClear:
            break
        }
        return api
    }

    /// Plants what an earlier process left behind: an attached reference
    /// (with `lastExit = parked` for the cloud fixtures), the pending cloud
    /// queue record at the head carrying its `parked` reason, and the server
    /// job in `seededServerState` under the reference's client request ID.
    /// Returns nil for fixtures that start from a clean process.
    @MainActor
    func seedPersistedState(
        store: RemoteTranscriptionJobStore,
        api: RemoteJobFaultInjectingAPI,
        modelContext: ModelContext,
        episode: EpisodeListItemSnapshot
    ) throws -> PersistedSeed? {
        guard let seededServerState else {
            return nil
        }
        let minted = store.reference(for: episode.episodeID, purpose: purpose)
        store.attachJob(id: Self.seededJobID, episodeID: episode.episodeID, purpose: purpose)
        var queueRecordEpisodeID: String?
        if purpose == .adDetection {
            store.recordExit(.parked, episodeID: episode.episodeID, purpose: purpose)
            modelContext.insert(AdFreePassQueueItemRecord(
                episodeID: episode.episodeID,
                podcastID: episode.podcastID,
                originRawValue: AdFreePassQueueOrigin.manual.rawValue,
                sequence: 1,
                modeRawValue: AdDetectionMode.cloud.rawValue,
                remoteParkReasonRawValue: RemoteTranscriptionJobExit.parked.rawValue
            ))
            try modelContext.save()
            queueRecordEpisodeID = episode.episodeID
        }
        api.seedServerJob(
            clientRequestID: minted.clientRequestID,
            jobID: Self.seededJobID,
            state: seededServerState
        )
        let reference = store.references().first {
            $0.episodeID == episode.episodeID && $0.resolvedPurpose == purpose
        }
        return PersistedSeed(
            reference: reference ?? minted,
            jobID: Self.seededJobID,
            queueRecordEpisodeID: queueRecordEpisodeID
        )
    }

    private var pollScript: [OpenCastRemoteTranscriptionJobStatus] {
        let states: [OpenCastRemoteTranscriptionJobState] = switch self {
        case .createNeverLeaves, .createAcceptedResponseLost, .createDelayedThenUserCancels:
            [.created]
        case .cancelResponseLost, .transportAfterAttach, .localLegFailure, .cloudParked, .parkedCloudUserCancel:
            [.transcribing]
        case .deathAfterImport, .ownerBeforeClear:
            [.resultReady]
        case .deathAfterAck, .acknowledgedWithoutImport:
            [.acknowledged]
        }
        return states.map { OpenCastRemoteTranscriptionJobStatus(jobID: "", state: $0) }
    }
}
