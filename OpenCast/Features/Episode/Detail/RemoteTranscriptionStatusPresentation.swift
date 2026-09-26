/// Pure mapping from a remote transcription phase to the episode-detail
/// status card. `nil` hides the card: no request, or it completed and the
/// transcript entry card takes over. Every terminal non-completed phase
/// renders — a remote job never ends silently — and a parked job renders as
/// still running on the server with Resume, never as a failure.
nonisolated struct RemoteTranscriptionStatusPresentation: Equatable {
    let title: String
    let detail: String?
    let secondaryDetail: String?
    let progressFraction: Double?
    let isTerminalFailure: Bool
    /// Local polling stopped while the server keeps working; the job is
    /// re-attachable and a user cancel is still available.
    let isParked: Bool
    let offersLocalFallback: Bool
    /// Re-attaches the same persisted reference.
    let offersResume: Bool
    /// Re-runs against the same job, or a fresh one once the server result
    /// is gone.
    let offersRetry: Bool

    static let localFallbackActionTitle = "Transcribe on Device"
    static let resumeActionTitle = "Resume"
    static let retryActionTitle = "Try Again"
    static let parkedTitle = "Still running on the server"

    static func make(phase: RemoteTranscriptionRequestPhase?) -> RemoteTranscriptionStatusPresentation? {
        guard let phase else {
            return nil
        }
        switch phase {
        case .completed:
            return nil
        case .mismatchLocalFallback:
            return terminal(
                title: "Server audio differed",
                detail: "The server fetched different audio than this device has. Transcribe on this device instead."
            )
        case .cancelled:
            return terminal(
                title: "Remote transcription cancelled",
                detail: "You can transcribe on this device instead."
            )
        case let .failed(category):
            return terminal(
                title: failedTitle(for: category),
                detail: category.message,
                offersResume: category == .connectionLost,
                offersRetry: category.offersRetry
            )
        case let .parkedOnServer(exit):
            return RemoteTranscriptionStatusPresentation(
                title: parkedTitle,
                detail: parkedDetail(for: exit),
                secondaryDetail: nil,
                progressFraction: nil,
                isTerminalFailure: false,
                isParked: true,
                offersLocalFallback: false,
                offersResume: true,
                offersRetry: false
            )
        case let .uploadingExactCopy(completed, total):
            return live(
                detail: total > 0
                    ? "Uploading this device's exact copy — \(completed) of \(total) parts. Continues in the background."
                    : "Uploading this device's exact copy. Continues in the background."
            )
        case let .processing(progress):
            return live(
                detail: progress.stage.displayText,
                secondaryDetail: progress.estimate?.displayText,
                progressFraction: progress.fractionCompleted
            )
        case .preparing, .downloadingBoth, .verifying, .waitingForCredits, .saving:
            return live(detail: phase.displayText)
        }
    }

    private static func failedTitle(for category: RemoteTranscriptionFailureCategory) -> String {
        switch category {
        case .acknowledgedWithoutLocalImport:
            "Transcript wasn't saved on this device"
        case .connectionLost:
            parkedTitle
        default:
            "Remote transcription didn't finish"
        }
    }

    private static func parkedDetail(for exit: RemoteTranscriptionJobExit) -> String {
        switch exit {
        case .parked:
            "Progress updates paused while the app was in the background. Resume to pick the job back up."
        case .connectionLost:
            "Lost the connection while the server was still working. Resume to check on the same job."
        case .localRequestFailed:
            "This device couldn't complete a request. Resume to try again on the same job."
        case .downloadFailed:
            "The episode download didn't finish. Resume once the download is available."
        }
    }

    private static func live(
        detail: String,
        secondaryDetail: String? = nil,
        progressFraction: Double? = nil
    ) -> RemoteTranscriptionStatusPresentation {
        RemoteTranscriptionStatusPresentation(
            title: "Remote transcription",
            detail: detail,
            secondaryDetail: secondaryDetail,
            progressFraction: progressFraction,
            isTerminalFailure: false,
            isParked: false,
            offersLocalFallback: false,
            offersResume: false,
            offersRetry: false
        )
    }

    private static func terminal(
        title: String,
        detail: String,
        offersResume: Bool = false,
        offersRetry: Bool = false
    ) -> RemoteTranscriptionStatusPresentation {
        RemoteTranscriptionStatusPresentation(
            title: title,
            detail: detail,
            secondaryDetail: nil,
            progressFraction: nil,
            isTerminalFailure: true,
            isParked: false,
            offersLocalFallback: true,
            offersResume: offersResume,
            offersRetry: offersRetry
        )
    }
}
