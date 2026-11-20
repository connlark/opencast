import CarPlay

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
        apply(state)
    }

    /// The row is replaced wholesale, so an unchanged state must not reach the
    /// head unit as a rebuild.
    func apply(_ state: CarPlayNowPlayingButtonState) {
        guard appliedState != state else {
            return
        }

        appliedState = state
        template.upNextTitle = state.upNextTitle
        template.isAlbumArtistButtonEnabled = state.canShowCurrentShow
        template.updateNowPlayingButtons(makeButtons(for: state))
    }

    /// The shared template outlives the connection, so the observer must detach. The row is
    /// left as it is: the next connect rebuilds it.
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

        return [rate, voiceBoost]
    }

    /// The system recolors image buttons, so the glyph is a plain template symbol. CarPlay shows
    /// a placeholder for an empty image rather than failing the row.
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
