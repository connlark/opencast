enum CompletionDeliveryDecision: Equatable {
    case scheduled
    case suppressed(Suppression)
    case addFailed

    enum Suppression: Equatable {
        case remoteOwner
        case sceneActive
        case unauthorized
        case silentOutcome
    }

    func diagnosticEvent(
        episodeID: String,
        reference: RemoteTranscriptionJobReference?,
        purpose: RemoteTranscriptionJobPurpose
    ) -> RemoteJobDiagnosticEvent {
        RemoteJobDiagnosticEvent(
            component: .completionDelivery,
            kind: self == .scheduled ? .notificationScheduled : .notificationSuppressed,
            episodeID: episodeID,
            jobID: reference?.jobID,
            clientRequestID: reference?.clientRequestID,
            purpose: purpose,
            disposition: diagnosticDisposition
        )
    }

    private var diagnosticDisposition: RemoteJobDiagnosticEvent.Disposition? {
        switch self {
        case .scheduled:
            nil
        case .suppressed(.remoteOwner):
            .suppressedRemoteOwner
        case .suppressed(.sceneActive):
            .suppressedSceneActive
        case .suppressed(.unauthorized):
            .suppressedUnauthorized
        case .suppressed(.silentOutcome):
            .suppressedSilentOutcome
        case .addFailed:
            .deliveryFailed
        }
    }
}
