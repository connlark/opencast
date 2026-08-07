/// Everything the Now Playing screen's custom row and its two navigation
/// affordances render from. Equatable because the observation loop rebuilds the
/// whole row on change, and a row rebuilt for an unchanged value is churn the
/// head unit sees.
nonisolated struct CarPlayNowPlayingButtonState: Equatable, Sendable {
    static let idle = CarPlayNowPlayingButtonState(
        rate: 1,
        hasLoadedEpisode: false,
        isVoiceBoostOn: false,
        canToggleVoiceBoost: false,
        canShowCurrentShow: false,
        upNextTitle: "Inbox"
    )

    let rate: Float
    let hasLoadedEpisode: Bool
    let isVoiceBoostOn: Bool
    let canToggleVoiceBoost: Bool
    let canShowCurrentShow: Bool
    let upNextTitle: String
}
