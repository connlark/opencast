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
