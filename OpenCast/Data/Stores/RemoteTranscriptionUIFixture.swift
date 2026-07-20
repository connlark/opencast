import Foundation
import OpenCastTranscription

#if DEBUG
/// Launch-argument UI fixtures for the remote transcription states pass 0
/// actually has: `-OPENCAST_REMOTE_TRANSCRIPTION_FIXTURE <name>[:<episodeID>]`
/// drives the observable job store into one state with no server, StoreKit,
/// or network involved. Combine with `-OPENCAST_REMOTE_TRANSCRIPTION_DEV` so
/// the gated UI renders. Debug builds only; release compiles none of this.
enum RemoteTranscriptionUIFixture: String, CaseIterable {
    case devBalance = "dev-balance"
    case hashMatchInProgress = "hash-match"
    case transcribing
    /// Exact-device upload fallback in flight (pass 2).
    case uploading
    case resultImported = "result-imported"
    case mismatchLocalFallback = "mismatch"
    /// Server ended the job `failed` mid-transcription with a stable code.
    case serverFailure = "failure"
    /// Poll timeout / unreachable backend mid-flow.
    case unreachableFailure = "unreachable"
    case cancelled

    static let launchArgument = "-OPENCAST_REMOTE_TRANSCRIPTION_FIXTURE"
    static let defaultEpisodeID = "fixture-episode"

    static func fromLaunchArguments(
        _ arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> (fixture: RemoteTranscriptionUIFixture, episodeID: String)? {
        guard let index = arguments.firstIndex(of: launchArgument),
              arguments.indices.contains(index + 1)
        else {
            return nil
        }
        let parts = arguments[index + 1].split(separator: ":", maxSplits: 1).map(String.init)
        guard let first = parts.first, let fixture = RemoteTranscriptionUIFixture(rawValue: first) else {
            return nil
        }
        return (fixture, parts.count > 1 ? parts[1] : defaultEpisodeID)
    }

    /// Mirrors exactly the store transitions the coordinator would make for
    /// this state; in-progress states park a real task so active-request
    /// gating and Cancel behave like a live request.
    func apply(to store: RemoteTranscriptionJobStore, episodeID: String) {
        store.updateAccount(
            OpenCastRemoteTranscriptionBootstrapResponse(
                schemaVersion: OpenCastRemoteTranscriptionSchema.version,
                accountID: "fixture-account",
                balance: OpenCastRemoteTranscriptionBalance(availableSeconds: 33_959, reservedSeconds: 0)
            )
        )
        switch self {
        case .devBalance:
            break
        case .hashMatchInProgress:
            beginParked(store: store, episodeID: episodeID)
            store.update(phase: .verifying)
        case .transcribing:
            beginParked(store: store, episodeID: episodeID)
            store.update(phase: .processing(RemoteTranscriptionActiveProgress(
                stage: .transcribing,
                completedChunks: 3,
                totalChunks: 7,
                fractionCompleted: 3.0 / 7.0,
                estimate: .onTrack(remainingSeconds: 52)
            )))
        case .uploading:
            beginParked(store: store, episodeID: episodeID)
            store.update(phase: .uploadingExactCopy(completedParts: 2, totalParts: 5))
        case .resultImported:
            store.begin(episodeID: episodeID, title: "Fixture Episode")
            store.finish(phase: .completed)
        case .mismatchLocalFallback:
            store.begin(episodeID: episodeID, title: "Fixture Episode")
            store.finish(phase: .mismatchLocalFallback)
        case .serverFailure:
            store.begin(episodeID: episodeID, title: "Fixture Episode")
            store.finish(phase: .failed(.serverRejected(.transcriptionFailed)))
        case .unreachableFailure:
            store.begin(episodeID: episodeID, title: "Fixture Episode")
            store.finish(phase: .failed(.serviceUnavailable))
        case .cancelled:
            store.begin(episodeID: episodeID, title: "Fixture Episode")
            store.finish(phase: .cancelled)
        }
    }

    private func beginParked(store: RemoteTranscriptionJobStore, episodeID: String) {
        store.begin(episodeID: episodeID, title: "Fixture Episode")
        store.activeTask = Task {
            try? await Task.sleep(for: .seconds(3600))
        }
    }
}
#endif
