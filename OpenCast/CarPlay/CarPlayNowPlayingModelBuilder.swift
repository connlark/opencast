import Foundation

/// Maps store state to the Now Playing screen's button row. Pure, so the
/// surface that has no UI-test bridge stays covered by plain unit tests.
enum CarPlayNowPlayingModelBuilder {
    static func buttonState(
        rate: Float,
        hasLoadedEpisode: Bool,
        isCurrentShowSubscribed: Bool,
        isVoiceBoostEnabled: Bool,
        canChangeVoiceBoost: Bool,
        hasQueuedEpisodes: Bool
    ) -> CarPlayNowPlayingButtonState {
        CarPlayNowPlayingButtonState(
            rate: rate,
            hasLoadedEpisode: hasLoadedEpisode,
            // In a global Voice Boost mode the button still reports the state it
            // cannot change, which reads better than an inert gap in the row.
            isVoiceBoostOn: isVoiceBoostEnabled,
            canToggleVoiceBoost: hasLoadedEpisode && canChangeVoiceBoost,
            // An orphaned download's show was unsubscribed, so there is no show
            // list left to push.
            canShowCurrentShow: hasLoadedEpisode && isCurrentShowSubscribed,
            upNextTitle: hasQueuedEpisodes ? "Up Next" : "Inbox"
        )
    }
}
