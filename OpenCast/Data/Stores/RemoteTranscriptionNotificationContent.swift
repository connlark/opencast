struct RemoteTranscriptionNotificationContent: Equatable {
    enum Kind: Equatable {
        case completed
        case paused
        case failed
    }

    let kind: Kind
    let title: String
    let body: String

    init?(
        phase: RemoteTranscriptionRequestPhase,
        episodeTitle: String?,
        createState: RemoteTranscriptionJobCreateState? = nil
    ) {
        switch phase {
        case .completed:
            kind = .completed
            title = "Transcript ready"
            body = episodeTitle ?? ""
        case .parkedOnServer(let exit):
            guard let copy = Self.pausedCopy(for: exit) else {
                return nil
            }
            kind = .paused
            switch createState {
            case .createAttempted, .attached:
                title = copy.title
                body = copy.body
            case .prepared, nil:
                title = "Remote transcription paused"
                body = "The server job hasn't started. Open OpenCast and resume to try again."
            }
        case .failed, .mismatchLocalFallback:
            guard let presentation = RemoteTranscriptionStatusPresentation.make(phase: phase),
                  let detail = presentation.detail
            else {
                return nil
            }
            kind = .failed
            title = presentation.title
            body = detail
        case .cancelled, .preparing, .downloadingBoth, .verifying, .uploadingExactCopy,
             .waitingForCredits, .processing, .saving:
            return nil
        }
    }

    /// The paused copy is local lifecycle feedback, so it posts whoever owns delivery.
    var honorsDeliveryOwner: Bool {
        kind != .paused
    }

    /// Only an expiration park is certain to happen while the person is away; a connection
    /// loss can surface as the app returns from suspension.
    static func pausedCopy(for exit: RemoteTranscriptionJobExit) -> (title: String, body: String)? {
        guard exit == .parked else {
            return nil
        }
        return (
            RemoteTranscriptionStatusPresentation.parkedTitle,
            RemoteTranscriptionStatusPresentation.parkedDetail(for: exit)
        )
    }
}
