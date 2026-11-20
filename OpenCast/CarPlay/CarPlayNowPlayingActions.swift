/// Every effect on stores, playback and the template stack stays behind these closures; the
/// configurator owns only the CarPlay objects.
struct CarPlayNowPlayingActions {
    let cycleRate: () -> Void
    let toggleVoiceBoost: () -> Void
    let showUpNext: () -> Void
    let showCurrentShow: () -> Void
}
