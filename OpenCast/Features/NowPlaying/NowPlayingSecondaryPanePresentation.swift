import CoreGraphics

nonisolated struct NowPlayingSecondaryPanePresentation: Equatable, Sendable {
    let style: NowPlayingSecondaryPaneStyle
    let selection: NowPlayingSecondaryPane
    let isExpanded: Bool
    /// Nil while an open sheet already shows the selection.
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

    var showsPane: Bool {
        style == .beside || isExpanded
    }

    /// At least a picker and three queue rows, at most the beside pane's height on the same
    /// display.
    static func inlineHeight(viewportHeight: CGFloat) -> CGFloat {
        (viewportHeight * 0.6).clamped(to: inlineHeightRange)
    }

    static let inlineHeightRange: ClosedRange<CGFloat> = 280...480
}
