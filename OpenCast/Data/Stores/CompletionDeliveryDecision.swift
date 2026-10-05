/// How one local completion-delivery request ended. Each case is also the
/// `completionDelivery` event the remote-job trail records for it.
enum CompletionDeliveryDecision: Equatable {
    case scheduled
    case suppressed(Suppression)
    /// The notification center refused the request.
    case addFailed

    enum Suppression: Equatable {
        /// A remote owner delivers this completion, so the device stays
        /// quiet.
        case remoteOwner
        /// The person is in the app, and `willPresent` would banner it.
        case sceneActive
        /// Notifications are denied or not yet determined.
        case unauthorized
        /// The outcome never notifies, like a cancel or a connection-loss
        /// park.
        case silentOutcome
    }

    /// The trail event for this decision. A cleared reference leaves the
    /// job ids out; the episode and purpose still correlate it with the
    /// run's own events.
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
