import CoreGraphics

nonisolated struct NowPlayingSoundLabLayout {
    static let artworkVisibleFraction: CGFloat = 0.18
    static let iconOnlyRowAreaWidth: CGFloat = 195
    static let controlRowHeight: CGFloat = 56
    static let controlIconDiameter: CGFloat = 24
    static let controlHorizontalPadding: CGFloat = 5
    static let nativeGlassButtonLeadingInset: CGFloat = 11
    static let controlSpacing: CGFloat = 6
    static let trailingIndicatorSize: CGFloat = 16

    let contentInset: CGFloat
    let artworkRailWidth: CGFloat
    let artworkGutter: CGFloat
    let rowAreaWidth: CGFloat

    init(panelWidth: CGFloat) {
        contentInset = max(9, panelWidth * 0.035)
        artworkRailWidth = min(54, max(40, panelWidth * Self.artworkVisibleFraction))
        artworkGutter = 4
        rowAreaWidth = max(
            0,
            panelWidth - contentInset - artworkRailWidth - artworkGutter
        )
    }

    static func collapsesToIconOnly(
        rowAreaWidth: CGFloat,
        isAccessibilitySize: Bool
    ) -> Bool {
        isAccessibilitySize || rowAreaWidth < iconOnlyRowAreaWidth
    }
}
