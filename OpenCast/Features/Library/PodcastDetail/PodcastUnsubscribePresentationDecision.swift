nonisolated struct PodcastUnsubscribePresentationDecision: Equatable, Sendable {
    let emitsSuccessFeedback: Bool
    let dismissesImmediately: Bool
    let alertTitle: String?
    let alertMessage: String?
    let dismissesAfterAlert: Bool

    static func make(
        outcome: PodcastUnsubscribeOutcome
    ) -> PodcastUnsubscribePresentationDecision {
        switch outcome {
        case .removed(warning: nil):
            PodcastUnsubscribePresentationDecision(
                emitsSuccessFeedback: true,
                dismissesImmediately: true,
                alertTitle: nil,
                alertMessage: nil,
                dismissesAfterAlert: false
            )
        case .removed(let warning?):
            PodcastUnsubscribePresentationDecision(
                emitsSuccessFeedback: true,
                dismissesImmediately: false,
                alertTitle: "Podcast Removed with Cleanup Warning",
                alertMessage: warning,
                dismissesAfterAlert: true
            )
        case .failed(let message):
            PodcastUnsubscribePresentationDecision(
                emitsSuccessFeedback: false,
                dismissesImmediately: false,
                alertTitle: "Couldn’t Unsubscribe",
                alertMessage: message,
                dismissesAfterAlert: false
            )
        }
    }
}
