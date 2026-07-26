/// What a tap on the Now Playing screen asks the coordinator to do. The
/// configurator owns the CarPlay objects; every effect on stores, playback, and
/// the template stack stays on the far side of these closures.
struct CarPlayNowPlayingActions {
    let cycleRate: () -> Void
    let toggleVoiceBoost: () -> Void
    let showUpNext: () -> Void
    let showCurrentShow: () -> Void
}
