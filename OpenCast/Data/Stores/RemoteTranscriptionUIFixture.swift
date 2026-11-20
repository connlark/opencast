import Foundation
import OpenCastTranscription

#if DEBUG
/// The gated UI renders only with `-OPENCAST_REMOTE_TRANSCRIPTION_DEV` also passed.
enum RemoteTranscriptionUIFixture: String, CaseIterable {
    case devBalance = "dev-balance"
    case hashMatchInProgress = "hash-match"
    case transcribing
    case uploading
    case resultImported = "result-imported"
    case mismatchLocalFallback = "mismatch"
    case serverFailure = "failure"
    case unreachableFailure = "unreachable"
    case parked
    case connectionLost = "connection-lost"
    case localRequestFailed = "local-request-failed"
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
        case .parked:
            store.begin(episodeID: episodeID, title: "Fixture Episode")
            store.finish(phase: .parkedOnServer(.parked))
        case .connectionLost:
            store.begin(episodeID: episodeID, title: "Fixture Episode")
            store.finish(phase: .parkedOnServer(.connectionLost))
        case .localRequestFailed:
            store.begin(episodeID: episodeID, title: "Fixture Episode")
            store.finish(phase: .failed(.localRequestFailed))
        case .cancelled:
            store.begin(episodeID: episodeID, title: "Fixture Episode")
            store.finish(phase: .cancelled)
        }
    }

    /// A real task, so active-request gating and Cancel behave as for a live request.
    private func beginParked(store: RemoteTranscriptionJobStore, episodeID: String) {
        store.begin(episodeID: episodeID, title: "Fixture Episode")
        store.activeTask = Task {
            try? await Task.sleep(for: .seconds(3600))
        }
    }
}
#endif
