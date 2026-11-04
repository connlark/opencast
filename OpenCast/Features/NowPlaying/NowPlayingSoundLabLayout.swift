import CoreGraphics

nonisolated struct NowPlayingSoundLabLayout {
    static let artworkVisibleFraction: CGFloat = 0.18
    static let controlRowHeight: CGFloat = 56
    /// The row height wherever the panel is short or the text is an
    /// accessibility size.
    static let compactRowHeight: CGFloat = 44
    /// The gaps between compact rows close no further than this.
    static let minimumRowSpacing: CGFloat = 2
    static let controlIconDiameter: CGFloat = 24
    static let controlHorizontalPadding: CGFloat = 5
    static let nativeGlassButtonLeadingInset: CGFloat = 11
    static let controlSpacing: CGFloat = 6
    static let trailingIndicatorSize: CGFloat = 16

    static let minimumContentInset: CGFloat = 9
    static let contentInsetFraction: CGFloat = 0.035
    static let artworkGutter: CGFloat = 4
    static let minimumArtworkRailWidth: CGFloat = 40
    static let maximumArtworkRailWidth: CGFloat = 54

    static let railCapsuleWidth: CGFloat = 3
    static let railCapsuleHeight: CGFloat = 11
    static let railCapsuleSpacing: CGFloat = 8
    static let maximumRailCapsuleCount = 12
    static let minimumHitTarget: CGFloat = 44

    /// The system switch's width, and the toggle's gap between its title and
    /// the switch (iOS 27.2, measured by `NowPlayingSoundLabLayoutTests`).
    static let systemSwitchWidth: CGFloat = 61
    static let toggleTitleGap: CGFloat = 8
    /// "Voice Boost" in `.subheadline` at the default text size, rounded up
    /// from the measured 81.4 pt.
    static let voiceBoostTitleWidth: CGFloat = 82

    /// Everything in the Voice Boost toggle row but its title: leading
    /// padding and glass inset, the icon, its spacing, the toggle's gap and
    /// switch, trailing padding. Idle, it is the tightest labeled row; an
    /// action row has no switch, and only a busy one adds its state glyph.
    static let labeledToggleFixedWidth: CGFloat = controlHorizontalPadding + nativeGlassButtonLeadingInset
        + controlIconDiameter + controlSpacing + toggleTitleGap + systemSwitchWidth + controlHorizontalPadding

    /// The narrowest row space that keeps the titles: the toggle row's fixed
    /// parts plus its whole title at the default text size (120 + 82 = 202;
    /// the row measured 201.7 pt). Narrower rows show their icons only, the
    /// full title staying the accessibility label; accessibility text sizes
    /// always do. The space is the panel's own (`rowAreaWidth`), never the
    /// window's.
    static let iconOnlyRowAreaWidth = labeledToggleFixedWidth + voiceBoostTitleWidth

    /// The narrowest rail: one capsule beside the minimum inset.
    static let minimumRailStrip = minimumContentInset + railCapsuleWidth

    /// The three compact rows the panel can show (Voice Boost, the ad-free
    /// pass, the transcript).
    static let maximumRowCount = 3

    /// The smallest square that holds the panel's content: the icon-only
    /// toggle row beside the narrowest rail (120 + 9 + 4 + 12 = 145), and the
    /// three compact rows with their tightest gaps between both insets
    /// (3 × 44 + 2 × 2 + 2 × 9 = 154). Below it the controls cannot render
    /// inline whole.
    static let inlineFloor = max(
        labeledToggleFixedWidth + minimumContentInset + artworkGutter + minimumRailStrip,
        CGFloat(maximumRowCount) * compactRowHeight
            + CGFloat(maximumRowCount - 1) * minimumRowSpacing
            + 2 * minimumContentInset
    )

    /// Below this height, or at an accessibility size, the rows are compact
    /// and the header is hidden; above `roomyPanelHeight` the roomy rows
    /// spread a little further.
    static let compactPanelHeight: CGFloat = 250
    static let roomyPanelHeight: CGFloat = 290

    struct RowMetrics: Equatable {
        let rowHeight: CGFloat
        let rowSpacing: CGFloat
        let showsHeader: Bool
    }

    let contentInset: CGFloat
    let artworkRailWidth: CGFloat
    let artworkGutter: CGFloat
    let rowAreaWidth: CGFloat
    /// The artwork left showing at the leading edge while the panel is open.
    let artworkExposedWidth: CGFloat

    /// The rows take the icon-only toggle row's width first; the rail and
    /// the exposed artwork keep the leading space that leaves, up to today's
    /// rail and today's 18 %. From 173 pt the rail is today's again, and
    /// the exposed artwork from 162.2 pt.
    init(panelWidth: CGFloat) {
        contentInset = max(Self.minimumContentInset, panelWidth * Self.contentInsetFraction)
        artworkGutter = Self.artworkGutter
        let leadingSpaceBesideRows = max(
            Self.minimumRailStrip,
            panelWidth - contentInset - artworkGutter - Self.labeledToggleFixedWidth
        )
        let todaysRail = min(
            Self.maximumArtworkRailWidth,
            max(Self.minimumArtworkRailWidth, panelWidth * Self.artworkVisibleFraction)
        )
        artworkRailWidth = min(todaysRail, leadingSpaceBesideRows)
        artworkExposedWidth = min(panelWidth * Self.artworkVisibleFraction, leadingSpaceBesideRows)
        rowAreaWidth = max(
            0,
            panelWidth - contentInset - artworkRailWidth - artworkGutter
        )
    }

    var protectedLeadingSpace: CGFloat {
        artworkRailWidth + artworkGutter
    }

    /// The artwork's tap-and-drag target across the panel. Closed or mid-drag
    /// it is the whole square. Settled open it ends where the rows begin, or
    /// where the visible artwork ends if that is further, so it never takes a
    /// control's tap yet covers all the artwork showing; and it is at least
    /// 44 pt wide, a narrower span growing out past the artwork's leading
    /// edge rather than over a row.
    func artworkHitSpan(panelSide: CGFloat, isSettledOpen: Bool) -> ClosedRange<CGFloat> {
        guard isSettledOpen else {
            return 0...panelSide
        }
        let trailingEdge = max(protectedLeadingSpace, artworkExposedWidth)
        return (trailingEdge - max(Self.minimumHitTarget, trailingEdge))...trailingEdge
    }

    static func collapsesToIconOnly(
        rowAreaWidth: CGFloat,
        isAccessibilitySize: Bool
    ) -> Bool {
        isAccessibilitySize || rowAreaWidth < iconOnlyRowAreaWidth
    }

    static func rowMetrics(
        panelHeight: CGFloat,
        verticalInset: CGFloat,
        rowCount: Int,
        isAccessibilitySize: Bool
    ) -> RowMetrics {
        guard isAccessibilitySize || panelHeight < compactPanelHeight else {
            return RowMetrics(
                rowHeight: controlRowHeight,
                rowSpacing: panelHeight > roomyPanelHeight ? 7 : 5,
                showsHeader: true
            )
        }
        return RowMetrics(
            rowHeight: compactRowHeight,
            rowSpacing: constrainedRowSpacing(
                panelHeight: panelHeight,
                verticalInset: verticalInset,
                rowCount: rowCount,
                rowHeight: compactRowHeight
            ),
            showsHeader: false
        )
    }

    /// 14 pt between the compact rows while the panel has the room; a
    /// shorter panel (down to the inline floor for three rows) closes the
    /// gaps toward 2 pt instead of clipping a row.
    static func constrainedRowSpacing(
        panelHeight: CGFloat,
        verticalInset: CGFloat,
        rowCount: Int,
        rowHeight: CGFloat
    ) -> CGFloat {
        guard rowCount > 1 else {
            return 14
        }
        let room = panelHeight - 2 * verticalInset - CGFloat(rowCount) * rowHeight
        return min(14, max(minimumRowSpacing, room / CGFloat(rowCount - 1)))
    }

    static func showsInline(panelSide: CGFloat) -> Bool {
        panelSide >= inlineFloor
    }

    static func railCapsuleCount(panelHeight: CGFloat) -> Int {
        guard panelHeight.isFinite, panelHeight > 0 else {
            return 0
        }
        let pitch = railCapsuleHeight + railCapsuleSpacing
        let fitting = Int(((panelHeight + railCapsuleSpacing) / pitch).rounded(.down))
        return max(0, min(maximumRailCapsuleCount, fitting))
    }
}
