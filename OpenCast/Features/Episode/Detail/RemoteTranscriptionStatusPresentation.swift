/// Pure mapping from a remote transcription phase to the episode-detail
/// status card. `nil` hides the card: no request, or it completed and the
/// transcript entry card takes over. Every terminal non-completed phase
/// renders — a remote job never ends silently.
nonisolated struct RemoteTranscriptionStatusPresentation: Equatable {
    let title: String
    let detail: String?
    let secondaryDetail: String?
    let progressFraction: Double?
    let isTerminalFailure: Bool
    let offersLocalFallback: Bool

    static let localFallbackActionTitle = "Transcribe on Device"

    static func make(phase: RemoteTranscriptionRequestPhase?) -> RemoteTranscriptionStatusPresentation? {
        guard let phase else {
            return nil
        }
        switch phase {
        case .completed:
            return nil
        case .mismatchLocalFallback:
            return RemoteTranscriptionStatusPresentation(
                title: "Server audio differed",
                detail: "The server fetched different audio than this device has. Transcribe on this device instead.",
                secondaryDetail: nil,
                progressFraction: nil,
                isTerminalFailure: true,
                offersLocalFallback: true
            )
        case .cancelled:
            return RemoteTranscriptionStatusPresentation(
                title: "Remote transcription cancelled",
                detail: "You can transcribe on this device instead.",
                secondaryDetail: nil,
                progressFraction: nil,
                isTerminalFailure: true,
                offersLocalFallback: true
            )
        case let .failed(category):
            return RemoteTranscriptionStatusPresentation(
                title: "Remote transcription didn't finish",
                detail: category.message,
                secondaryDetail: nil,
                progressFraction: nil,
                isTerminalFailure: true,
                offersLocalFallback: true
            )
        case let .uploadingExactCopy(completed, total):
            return RemoteTranscriptionStatusPresentation(
                title: "Remote transcription",
                detail: total > 0
                    ? "Uploading this device's exact copy — \(completed) of \(total) parts. Continues in the background."
                    : "Uploading this device's exact copy. Continues in the background.",
                secondaryDetail: nil,
                progressFraction: nil,
                isTerminalFailure: false,
                offersLocalFallback: false
            )
        case let .processing(progress):
            return RemoteTranscriptionStatusPresentation(
                title: "Remote transcription",
                detail: progress.stage.displayText,
                secondaryDetail: progress.estimate?.displayText,
                progressFraction: progress.fractionCompleted,
                isTerminalFailure: false,
                offersLocalFallback: false
            )
        case .preparing, .downloadingBoth, .verifying, .waitingForCredits, .saving:
            return RemoteTranscriptionStatusPresentation(
                title: "Remote transcription",
                detail: phase.displayText,
                secondaryDetail: nil,
                progressFraction: nil,
                isTerminalFailure: false,
                offersLocalFallback: false
            )
        }
    }
}
