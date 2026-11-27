import CoreGraphics

nonisolated struct NowPlayingSoundLabLayout {
    static let artworkVisibleFraction: CGFloat = 0.18
    static let controlRowHeight: CGFloat = 56
    static let compactRowHeight: CGFloat = 44
    static let minimumRowSpacing: CGFloat = 2
    static let maximumCompactRowSpacing: CGFloat = 14
    static let titledRowSpacing: CGFloat = 5
    static let controlIconDiameter: CGFloat = 24
    static let controlHorizontalPadding: CGFloat = 5
    static let nativeGlassButtonLeadingInset: CGFloat = 11
    /// What the `.glass` button style adds beside its label on each side, as of iOS 27.2.
    static let nativeGlassButtonSideChrome: CGFloat = 12
    /// What `.glass` adds above and below its label at every size up to the first accessibility
    /// size, as of iOS 27.2.
    static let nativeGlassButtonVerticalChrome: CGFloat = 7
    static let controlSpacing: CGFloat = 6
    static let trailingIndicatorSize: CGFloat = 16
    static let trailingIndicatorMinimumGap: CGFloat = 2
    /// Below the heading, inside its measured height.
    static let headingBottomPadding: CGFloat = 3

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

    /// The system switch's width and the toggle's title gap, as of iOS 27.2.
    static let systemSwitchWidth: CGFloat = 61
    static let toggleTitleGap: CGFloat = 8
    /// "Voice Boost" in `.subheadline` at the default text size, rounded up
    /// from the measured 81.4 pt.
    static let voiceBoostTitleWidth: CGFloat = 82

    /// The Voice Boost row but its title. Idle, it is the tightest labeled row: an action row has
    /// no switch, and only a busy one adds its state glyph.
    static let labeledToggleFixedWidth: CGFloat = controlHorizontalPadding + nativeGlassButtonLeadingInset
        + controlIconDiameter + controlSpacing + toggleTitleGap + systemSwitchWidth + controlHorizontalPadding

    /// The narrowest row space that keeps the titles (120 + 82 = 202 pt). It is the panel's own
    /// `rowAreaWidth`, never the window's.
    static let iconOnlyRowAreaWidth = labeledToggleFixedWidth + voiceBoostTitleWidth

    /// `width` is the title's in `.subheadline` at the default text size, rounded up.
    struct ActionTitle: Equatable, Sendable {
        let title: String
        let width: CGFloat
    }

    /// Each is held whole beside its state glyph; parameterized titles are outside that guarantee.
    static let fixedActionTitles = [
        ActionTitle(title: "Skip Promos & Ads", width: 131),
        ActionTitle(title: "Reanalyze", width: 70),
        ActionTitle(title: "Detect Ads Again", width: 119),
        ActionTitle(title: "Detect on Device", width: 118),
        ActionTitle(title: "Resume", width: 55),
        ActionTitle(title: "Retry", width: 37),
        ActionTitle(title: "Transcribe", width: 73),
        ActionTitle(title: "Transcribe Remotely", width: 141),
        ActionTitle(title: "View Transcript", width: 107)
    ]

    static let glyphActionRowFixedWidth: CGFloat = 2 * (controlHorizontalPadding + nativeGlassButtonSideChrome)
        + controlIconDiameter + controlSpacing
        + controlSpacing + trailingIndicatorMinimumGap + controlSpacing
        + trailingIndicatorSize

    /// Past this row space no fixed title gains anything, so an open panel grows no further.
    static let titledRowAreaCap = max(
        iconOnlyRowAreaWidth,
        glyphActionRowFixedWidth + (fixedActionTitles.map(\.width).max() ?? 0)
    )

    /// The exact panel widths that hold the titles at all, and all of them.
    static let titledMinimumWidth = panelWidth(forRowArea: iconOnlyRowAreaWidth)
    static let titledReferenceWidth = panelWidth(forRowArea: titledRowAreaCap)

    static let openPanelClearance: CGFloat = 8

    static let minimumRailStrip = minimumContentInset + railCapsuleWidth

    static let maximumRowCount = 3

    /// The smallest square that holds the controls inline whole.
    static let inlineFloor = max(
        labeledToggleFixedWidth + minimumContentInset + artworkGutter + minimumRailStrip,
        CGFloat(maximumRowCount) * compactRowHeight
            + CGFloat(maximumRowCount - 1) * minimumRowSpacing
            + 2 * minimumContentInset
    )

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

    /// The rows take the icon-only toggle row's width first; the rail and the exposed artwork
    /// keep what leading space that leaves.
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

    /// Settled open, the span never takes a control's tap yet covers all the artwork showing; a
    /// span under 44 pt grows out past the artwork's leading edge, never over a row.
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
                rowSpacing: panelHeight > roomyPanelHeight ? 7 : titledRowSpacing,
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

    static func constrainedRowSpacing(
        panelHeight: CGFloat,
        verticalInset: CGFloat,
        rowCount: Int,
        rowHeight: CGFloat
    ) -> CGFloat {
        guard rowCount > 1 else {
            return maximumCompactRowSpacing
        }
        let room = panelHeight - 2 * verticalInset - CGFloat(rowCount) * rowHeight
        return min(maximumCompactRowSpacing, max(minimumRowSpacing, room / CGFloat(rowCount - 1)))
    }

    /// Inverts `rowAreaWidth`: `0.785 w − 4` while the inset and the rail are proportional, and
    /// `0.965 w − 58` from 300 pt, where the rail reaches its cap.
    static func panelWidth(forRowArea rowArea: CGFloat) -> CGFloat {
        let proportional = (rowArea + artworkGutter) / (1 - contentInsetFraction - artworkVisibleFraction)
        guard proportional > maximumArtworkRailWidth / artworkVisibleFraction else {
            return proportional
        }
        return (rowArea + artworkGutter + maximumArtworkRailWidth) / (1 - contentInsetFraction)
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
