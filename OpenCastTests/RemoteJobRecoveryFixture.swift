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
enum RemoteJobRecoveryFixture: String, CaseIterable, Sendable {
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

    /// The pass whose focused suite owns the fixture's behavioral assertion.
    var owningPass: String {
        switch self {
        case .createNeverLeaves, .createAcceptedResponseLost, .createDelayedThenUserCancels,
             .cancelResponseLost, .transportAfterAttach, .localLegFailure,
             .deathAfterImport, .deathAfterAck, .acknowledgedWithoutImport:
            "01"
        case .cloudParked, .parkedCloudUserCancel:
            "03"
        case .ownerBeforeClear:
            "05"
        }
    }

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

    /// The persisted-reference and server-call assertion the owning test
    /// must make, in addition to the user-facing state it checks.
    var requiredAssertion: String {
        switch self {
        case .createNeverLeaves:
            "Reference stays prepared or safely retryable; no /cancel; the same client request ID is reused."
        case .createAcceptedResponseLost:
            "Reference is createAttempted without a jobID; re-attach repeats the same client request ID and discovers exactly one server job."
        case .createDelayedThenUserCancels:
            "Cancel intent persists; the returned or discovered job receives exactly one user cancel; no orphaned reference."
        case .cancelResponseLost:
            "Persisted user intent suppresses re-attach; cleanup retries as the same intent, never as an error path."
        case .transportAfterAttach:
            "Reference remains attached with lastExit connectionLost; no /cancel; Resume polls the same job."
        case .localLegFailure:
            "Bounded local retry then lastExit localRequestFailed; reference remains attached; no /cancel."
        case .deathAfterImport:
            "Re-run import is idempotent; ack clears the reference; one transcript."
        case .deathAfterAck:
            "acknowledged with local provenance is success; no serverRejected copy; reference cleared."
        case .acknowledgedWithoutImport:
            "acknowledged without local provenance emits acknowledgedWithoutLocalImport; no ordinary server-rejection copy."
        case .cloudParked:
            "Queue item persists the remote park reason; snapshot and pipeline show Resume; no /cancel; Resume attaches the seeded job."
        case .parkedCloudUserCancel:
            "The .adDetection cancel path runs before queue deletion; exactly one /cancel; no re-attach afterwards."
        case .ownerBeforeClear:
            "Outcome carries completionDeliveryOwner captured before the reference clear and filters correctly."
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
    /// queue record at the head, and the server job in `seededServerState`
    /// under the reference's client request ID. Returns nil for fixtures
    /// that start from a clean process.
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
                modeRawValue: AdDetectionMode.cloud.rawValue
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
