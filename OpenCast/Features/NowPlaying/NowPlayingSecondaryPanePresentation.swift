import CoreGraphics

/// What the secondary pane shows on this layout: its style from the
/// arrangement, the remembered selection, and the content it draws inline.
/// While an open sheet already shows the selected destination, the inline
/// copy is suppressed (`content` is nil) and returns once the sheet closes.
nonisolated struct NowPlayingSecondaryPanePresentation: Equatable, Sendable {
    let style: NowPlayingSecondaryPaneStyle
    let selection: NowPlayingSecondaryPane
    /// The disclosure row's state; the beside pane is always shown.
    let isExpanded: Bool
    /// The mode drawn inline, or nil when nothing is drawn inline.
    let content: NowPlayingSecondaryPane?

    init(
        arrangement: NowPlayingArrangement,
        selection: NowPlayingSecondaryPane,
        isDisclosureExpanded: Bool,
        presentedSheet: PlayerUtilitySheet?
    ) {
        let style = arrangement.paneStyle
        let isShown = switch style {
        case .entryPointsOnly:
            false
        case .beside:
            true
        case .disclosure:
            isDisclosureExpanded
        }
        let sheetShowsSelection = presentedSheet.flatMap(NowPlayingSecondaryPane.init(sheet:)) == selection
        self.style = style
        self.selection = selection
        isExpanded = style == .disclosure && isDisclosureExpanded
        content = isShown && !sheetShowsSelection ? selection : nil
    }

    /// The pane, or the disclosure row's expanded area, is on screen.
    var showsPane: Bool {
        style == .beside || isExpanded
    }

    /// The expanded row's bounded area: three fifths of the viewport it
    /// scrolls in, never shorter than a picker and three queue rows, never
    /// taller than the pane beside the player on the same display.
    static func inlineHeight(viewportHeight: CGFloat) -> CGFloat {
        (viewportHeight * 0.6).clamped(to: inlineHeightRange)
    }

    static let inlineHeightRange: ClosedRange<CGFloat> = 280...480
}
