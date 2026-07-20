/// Honest progress phases for a remote transcription request (parent plan's
/// list, including the exact-device upload fallback leg).
nonisolated enum RemoteTranscriptionRequestPhase: Equatable {
    case preparing
    case downloadingBoth
    case verifying
    /// The server requested the device's exact copy (fallback only): never
    /// shown on the normal simultaneous-download path.
    case uploadingExactCopy(completedParts: Int, totalParts: Int)
    case waitingForCredits
    case processing(RemoteTranscriptionActiveProgress)
    case saving
    case completed
    /// The server proved it fetched different bytes; the existing local
    /// transcription path is the way forward.
    case mismatchLocalFallback
    case failed(RemoteTranscriptionFailureCategory)
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .completed, .mismatchLocalFallback, .failed, .cancelled:
            true
        case .preparing, .downloadingBoth, .verifying, .uploadingExactCopy,
             .waitingForCredits, .processing, .saving:
            false
        }
    }

    var displayText: String {
        switch self {
        case .preparing: "Preparing"
        case .downloadingBoth: "Downloading on this device and server"
        case .verifying: "Verifying the audio"
        case let .uploadingExactCopy(completed, total):
            total > 0
                ? "Uploading this device's exact copy — \(completed) of \(total) parts"
                : "Uploading this device's exact copy"
        case .waitingForCredits: "Waiting for transcription time"
        case let .processing(progress): progress.stage.displayText
        case .saving: "Saving transcript"
        case .completed: "Completed"
        case .mismatchLocalFallback: "Server audio differed — use on-device transcription"
        case let .failed(category): category.message
        case .cancelled: "Cancelled"
        }
    }
}
