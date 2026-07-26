import CarPlay

/// Owns the shared Now Playing template: the custom button row, the Up Next and
/// album-artist affordances, and the observer that delivers their taps. The
/// system can present the shared template on the app's behalf at any time, so
/// this is configured when the car connects rather than when the app pushes it.
final class CarPlayNowPlayingConfigurator: NSObject {
    // The CarPlay asset table sizes now-playing glyphs at 20pt; anything larger
    // than `CPNowPlayingButtonMaximumImageSize` is scaled down by the system.
    private static let glyphConfiguration = UIImage.SymbolConfiguration(pointSize: 20)

    private let template: CPNowPlayingTemplate
    private let actions: CarPlayNowPlayingActions
    private var appliedState: CarPlayNowPlayingButtonState?

    init(template: CPNowPlayingTemplate = .shared, actions: CarPlayNowPlayingActions) {
        self.template = template
        self.actions = actions
        super.init()
    }

    func start(with state: CarPlayNowPlayingButtonState) {
        template.add(self)
        template.isUpNextButtonEnabled = true
        template.upNextTitle = "Inbox"
        apply(state)
    }

    /// The row is replaced wholesale, so an unchanged state must not reach the
    /// head unit as a rebuild.
    func apply(_ state: CarPlayNowPlayingButtonState) {
        guard appliedState != state else {
            return
        }

        appliedState = state
        template.isAlbumArtistButtonEnabled = state.canShowCurrentShow
        template.updateNowPlayingButtons(makeButtons(for: state))
    }

    /// The shared template outlives the connection, so a configurator that stays
    /// attached would keep handling taps for a session that is gone. The row
    /// itself is left alone: nothing renders it until the next connect, which
    /// rebuilds it.
    func tearDown() {
        template.remove(self)
        appliedState = nil
    }

    private func makeButtons(for state: CarPlayNowPlayingButtonState) -> [CPNowPlayingButton] {
        let rate = CPNowPlayingPlaybackRateButton { [weak self] _ in
            self?.actions.cycleRate()
        }
        rate.isEnabled = state.hasLoadedEpisode

        let voiceBoost = glyphButton(systemImageName: "waveform") { [weak self] in
            self?.actions.toggleVoiceBoost()
        }
        voiceBoost.isEnabled = state.canToggleVoiceBoost
        voiceBoost.isSelected = state.isVoiceBoostOn

        // Sleep and all ad controls remain phone-only.
        return [rate, voiceBoost]
    }

    /// Image buttons are recolored by the system, so the glyph ships as a plain
    /// template symbol. An empty image falls back to a system placeholder glyph
    /// rather than failing the row.
    private func glyphButton(
        systemImageName: String,
        handler: @escaping () -> Void
    ) -> CPNowPlayingImageButton {
        CPNowPlayingImageButton(
            image: UIImage(systemName: systemImageName, withConfiguration: Self.glyphConfiguration)
                ?? UIImage(),
            handler: { _ in handler() }
        )
    }
}

extension CarPlayNowPlayingConfigurator: CPNowPlayingTemplateObserver {
    func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        actions.showUpNext()
    }

    func nowPlayingTemplateAlbumArtistButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        actions.showCurrentShow()
    }
}
