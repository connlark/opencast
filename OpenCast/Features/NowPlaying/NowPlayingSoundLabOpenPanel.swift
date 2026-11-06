import SwiftUI

/// Where the Sound Lab opens. The panel takes the artwork's square unless a
/// wider rectangle over the same centre gets its rows their titles: first
/// with the heading, rising from the square's bottom edge; then, if the
/// square itself holds the rows, without it. Everything is in the card's
/// leading-relative coordinates, so a right-to-left card resolves the same.
nonisolated struct NowPlayingSoundLabOpenPanel: Equatable {
    enum Mode: Equatable {
        /// The square, laid out by `rowMetrics` and `collapsesToIconOnly`.
        case legacy
        case headed
        case headingless
    }

    struct Inputs {
        /// The artwork's square, card-local.
        let square: CGRect
        let contentSpan: ClosedRange<CGFloat>
        /// The viewport clipping the square, card-local.
        let viewport: CGRect
        let safeTop: CGFloat
        let moreFrame: CGRect
        let occlusions: [CGRect]
        let displayScale: CGFloat
        /// A corner of the physical pixel grid, card-local.
        let pixelGridOrigin: CGPoint
        let rowCount: Int
        let isAccessibilitySize: Bool
        /// The whole rendered heading with its bottom padding.
        let paddedHeadingHeight: CGFloat
    }

    /// What the player knows of the card around the square, handed to the
    /// artwork unchanged by anything it does. The square itself is measured
    /// there, in the coordinate space named here.
    struct CardContext: Equatable {
        static let coordinateSpaceName = "NowPlayingSoundLabCard"

        let cardWidth: CGFloat
        let contentWidth: CGFloat
        let viewport: CGRect
        let safeTop: CGFloat
        let moreFrame: CGRect
        let occlusions: [CGRect]
        let pixelGridOrigin: CGPoint

        init(cardGeometry: NowPlayingCardGeometry, contentWidth: CGFloat, viewport: CGRect) {
            cardWidth = cardGeometry.cardFrame.width
            self.contentWidth = contentWidth
            self.viewport = viewport
            safeTop = cardGeometry.contentInsets.top
            moreFrame = CGRect(
                origin: cardGeometry.moreOrigin,
                size: CGSize(width: NowPlayingCardGeometry.moreDiameter, height: NowPlayingCardGeometry.moreDiameter)
            )
            occlusions = cardGeometry.occlusions
            // The window's origin is a pixel corner, and the card's frame is
            // in the window's space.
            pixelGridOrigin = CGPoint(x: -cardGeometry.cardFrame.minX, y: -cardGeometry.cardFrame.minY)
        }

        var shape: ShapeKey.Card {
            ShapeKey.Card(
                cardWidth: cardWidth,
                contentWidth: contentWidth,
                viewport: viewport,
                safeTop: safeTop,
                moreFrame: moreFrame,
                occlusions: occlusions
            )
        }

        /// A named coordinate space reads from the card's left edge in either
        /// direction, and everything here reads from its leading one.
        func leadingRelative(_ measured: CGRect, isRightToLeft: Bool) -> CGRect {
            guard isRightToLeft else {
                return measured
            }
            return CGRect(
                x: cardWidth - measured.maxX,
                y: measured.minY,
                width: measured.width,
                height: measured.height
            )
        }

        /// The stack is centred on the square, so its span is too. Nil for a
        /// square or a width no span can be built from.
        func inputs(
            square: CGRect,
            displayScale: CGFloat,
            rowCount: Int,
            isAccessibilitySize: Bool,
            paddedHeadingHeight: CGFloat
        ) -> Inputs? {
            guard hasFiniteBounds(square), contentWidth.isFinite, contentWidth >= 0 else {
                return nil
            }
            return Inputs(
                square: square,
                contentSpan: (square.midX - contentWidth / 2)...(square.midX + contentWidth / 2),
                viewport: viewport,
                safeTop: safeTop,
                moreFrame: moreFrame,
                occlusions: occlusions,
                displayScale: displayScale,
                pixelGridOrigin: pixelGridOrigin,
                rowCount: rowCount,
                isAccessibilitySize: isAccessibilitySize,
                paddedHeadingHeight: paddedHeadingHeight
            )
        }
    }

    /// The rows of a titled panel.
    struct TitledRows: Equatable {
        let rowHeight: CGFloat
        /// Below the heading; nil without one.
        let headingGap: CGFloat?
        let rowGap: CGFloat
        /// What the heading, the rows and both insets leave of the height,
        /// split equally above and below them.
        let verticalRemainder: CGFloat

        var rowMetrics: NowPlayingSoundLabLayout.RowMetrics {
            NowPlayingSoundLabLayout.RowMetrics(
                rowHeight: rowHeight,
                rowSpacing: rowGap,
                showsHeader: headingGap != nil
            )
        }
    }

    /// What a panel's shape was resolved from. The square's position and the
    /// pixel grid's origin are left out, so a panel moves with its square
    /// without being resolved again; that is why this is a projection and
    /// never `CardContext` itself.
    struct ShapeKey: Equatable {
        /// The card's part of the key; absent with no card around the square.
        struct Card: Equatable {
            var cardWidth: CGFloat
            var contentWidth: CGFloat
            var viewport: CGRect
            var safeTop: CGFloat
            var moreFrame: CGRect
            var occlusions: [CGRect]
        }

        var side: CGFloat
        var dynamicTypeSize: DynamicTypeSize
        var reducesMotion: Bool
        var rowCount: Int
        var paddedHeadingHeight: CGFloat?
        var displayScale: CGFloat
        var layoutDirection: LayoutDirection
        var card: Card?

        /// The kept key still describes this one: exact, but for the side and
        /// the heading, which may differ from the kept values by a pixel.
        func holds(for current: ShapeKey) -> Bool {
            let pixel = (1 + pixelTolerance) / displayScale
            let sameHeading = switch (paddedHeadingHeight, current.paddedHeadingHeight) {
            case let (kept?, now?):
                abs(kept - now) <= pixel
            case (nil, nil):
                true
            default:
                false
            }
            return abs(side - current.side) <= pixel
                && sameHeading
                && dynamicTypeSize == current.dynamicTypeSize
                && reducesMotion == current.reducesMotion
                && rowCount == current.rowCount
                && displayScale == current.displayScale
                && layoutDirection == current.layoutDirection
                && card == current.card
        }
    }

    /// What an open panel does with the current key.
    enum Disposition: Equatable {
        case keep
        /// A panel that opened as the square stays the square, at today's side.
        case followAsLegacy
        case invalidate
    }

    /// A kept panel is never resolved again: it keeps its shape, or a titled
    /// one is closed. Only a closed panel resolves.
    static func disposition(keptMode: Mode, keptKey: ShapeKey, currentKey: ShapeKey) -> Disposition {
        guard keptMode != .legacy else {
            return .followAsLegacy
        }
        return keptKey.holds(for: currentKey) ? .keep : .invalidate
    }

    let mode: Mode
    /// Card-local; the square itself in the legacy mode.
    let frame: CGRect
    /// Nil in the legacy mode, whose rows are `rowMetrics`' for the square.
    let titledRows: TitledRows?

    /// Whether a square can open beyond itself at all. Accessibility sizes
    /// keep the square, a square below the floor keeps the sheet, and a
    /// square whose own rows reach the title threshold already has its titles.
    static func isEligible(side: CGFloat, isAccessibilitySize: Bool) -> Bool {
        !isAccessibilitySize
            && NowPlayingSoundLabLayout.showsInline(panelSide: side)
            && NowPlayingSoundLabLayout.collapsesToIconOnly(
                rowAreaWidth: NowPlayingSoundLabLayout(panelWidth: side).rowAreaWidth,
                isAccessibilitySize: false
            )
    }

    /// The square, for an artwork with no card around it to resolve against.
    static func legacy(side: CGFloat) -> Self {
        Self(mode: .legacy, frame: CGRect(x: 0, y: 0, width: side, height: side), titledRows: nil)
    }

    /// The artwork's tap-and-drag target, in the square's own coordinates of
    /// `side`. Settled open it is the layout's span from the open rectangle's
    /// leading edge, over the rectangle's height; otherwise the whole square.
    func artworkHitFrame(side: CGFloat, isSettledOpen: Bool) -> CGRect {
        guard isSettledOpen else {
            return CGRect(x: 0, y: 0, width: side, height: side)
        }
        let span = NowPlayingSoundLabLayout(panelWidth: frame.width)
            .artworkHitSpan(panelSide: frame.width, isSettledOpen: true)
        return CGRect(
            x: (side - frame.width) / 2 + span.lowerBound,
            y: side - frame.height,
            width: span.upperBound - span.lowerBound,
            height: frame.height
        )
    }

    init(_ inputs: Inputs) {
        let legacy = Self(mode: .legacy, frame: inputs.square, titledRows: nil)
        guard Self.isEligible(side: inputs.square.width, isAccessibilitySize: inputs.isAccessibilitySize) else {
            self = legacy
            return
        }
        // Transient layout can hand a view non-finite geometry, and the
        // square is the safe answer to it.
        guard inputs.rowCount > 0,
              inputs.displayScale.isFinite,
              inputs.displayScale > 0,
              inputs.paddedHeadingHeight.isFinite,
              inputs.paddedHeadingHeight >= 0,
              [
                  inputs.safeTop,
                  inputs.pixelGridOrigin.x,
                  inputs.pixelGridOrigin.y,
                  inputs.contentSpan.lowerBound,
                  inputs.contentSpan.upperBound
              ].allSatisfy({ $0.isFinite }),
              ([inputs.square, inputs.viewport, inputs.moreFrame] + inputs.occlusions)
                  .allSatisfy(Self.hasFiniteBounds)
        else {
            self = legacy
            return
        }
        self = Self.headed(inputs) ?? Self.headingless(inputs) ?? legacy
    }

    private init(mode: Mode, frame: CGRect, titledRows: TitledRows?) {
        self.mode = mode
        self.frame = frame
        self.titledRows = titledRows
    }

    private static func headed(_ inputs: Inputs) -> Self? {
        let square = inputs.square
        func fit(width: CGFloat) -> (height: CGFloat, rows: TitledRows) {
            headedFit(
                inset: NowPlayingSoundLabLayout(panelWidth: width).contentInset,
                side: square.height,
                heading: inputs.paddedHeadingHeight,
                rowCount: inputs.rowCount
            )
        }
        let frame = widestClearFrame(inputs) { width in
            let height = fit(width: width).height
            return CGRect(x: square.midX - width / 2, y: square.maxY - height, width: width, height: height)
        }
        return frame.map { Self(mode: .headed, frame: $0, titledRows: fit(width: $0.width).rows) }
    }

    /// The height of a headed panel and its rows, with `heading` G, `rowCount`
    /// n, and n equal gaps: one below the heading and n − 1 between the rows.
    /// Below `compactPanelHeight` the rows are compact and the height is the
    /// square or the rows at their tightest; it is never raised to widen a
    /// gap. From there up the rows and gaps are `rowMetrics`', at the smallest
    /// height that holds them.
    private static func headedFit(
        inset: CGFloat,
        side: CGFloat,
        heading: CGFloat,
        rowCount: Int
    ) -> (height: CGFloat, rows: TitledRows) {
        typealias Layout = NowPlayingSoundLabLayout
        let rows = CGFloat(rowCount)
        let fixedHeight = heading + 2 * inset

        let compactHeight = max(
            side,
            fixedHeight + rows * Layout.compactRowHeight + rows * Layout.titledRowSpacing
        )
        if compactHeight < Layout.compactPanelHeight {
            let gap = openedGap(
                room: compactHeight - fixedHeight - rows * Layout.compactRowHeight,
                gaps: rowCount
            )
            return (
                compactHeight,
                TitledRows(
                    rowHeight: Layout.compactRowHeight,
                    headingGap: gap,
                    rowGap: gap,
                    verticalRemainder: compactHeight - fixedHeight - rows * (Layout.compactRowHeight + gap)
                )
            )
        }

        func metrics(_ height: CGFloat) -> Layout.RowMetrics {
            Layout.rowMetrics(panelHeight: height, verticalInset: inset, rowCount: rowCount, isAccessibilitySize: false)
        }
        func held(at height: CGFloat) -> CGFloat {
            fixedHeight + rows * (metrics(height).rowHeight + metrics(height).rowSpacing)
        }
        // A second pass, because the height the first one reaches can be the
        // roomy tier's, whose gaps are wider.
        var height = max(side, Layout.compactPanelHeight)
        height = max(height, held(at: height))
        height = max(height, held(at: height))
        return (
            height,
            TitledRows(
                rowHeight: metrics(height).rowHeight,
                headingGap: metrics(height).rowSpacing,
                rowGap: metrics(height).rowSpacing,
                verticalRemainder: height - held(at: height)
            )
        )
    }

    private static func headingless(_ inputs: Inputs) -> Self? {
        typealias Layout = NowPlayingSoundLabLayout
        let square = inputs.square
        let frame = widestClearFrame(inputs) { width in
            CGRect(x: square.midX - width / 2, y: square.minY, width: width, height: square.height)
        }
        guard let frame else {
            return nil
        }
        let rows = CGFloat(inputs.rowCount)
        let gaps = inputs.rowCount - 1
        let room = square.height - 2 * Layout(panelWidth: frame.width).contentInset - rows * Layout.compactRowHeight
        guard room >= CGFloat(gaps) * Layout.titledRowSpacing else {
            return nil
        }
        let gap = openedGap(room: room, gaps: gaps)
        return Self(
            mode: .headingless,
            frame: frame,
            titledRows: TitledRows(
                rowHeight: Layout.compactRowHeight,
                headingGap: nil,
                rowGap: gap,
                verticalRemainder: room - CGFloat(gaps) * gap
            )
        )
    }

    /// Gaps open from `titledRowSpacing` toward the compact maximum as `room`
    /// allows.
    private static func openedGap(room: CGFloat, gaps: Int) -> CGFloat {
        typealias Layout = NowPlayingSoundLabLayout
        guard gaps > 0 else {
            return Layout.titledRowSpacing
        }
        return min(Layout.maximumCompactRowSpacing, max(Layout.titledRowSpacing, room / CGFloat(gaps)))
    }

    /// The widest frame on the display's grid of widths, from the reference
    /// width rounded up to the grid down to the narrowest that holds the
    /// titles, whose outward pixel coverage is clear and whose placed width
    /// still reaches the title threshold.
    private static func widestClearFrame(_ inputs: Inputs, frame: (CGFloat) -> CGRect) -> CGRect? {
        typealias Layout = NowPlayingSoundLabLayout
        let scale = inputs.displayScale
        guard let widest = Int(exactly: (Layout.titledReferenceWidth * scale).rounded(.up)),
              let narrowest = Int(exactly: (Layout.titledMinimumWidth * scale).rounded(.up)),
              narrowest > 0,
              widest >= narrowest
        else {
            return nil
        }
        for pixels in stride(from: widest, through: narrowest, by: -1) {
            let candidate = frame(CGFloat(pixels) / scale)
            if isClear(candidate, inputs),
               !Layout.collapsesToIconOnly(
                   rowAreaWidth: Layout(panelWidth: candidate.width).rowAreaWidth,
                   isAccessibilitySize: inputs.isAccessibilitySize
               ) {
                return candidate
            }
        }
        return nil
    }

    /// The frame's covered pixels stay in the content span, in the viewport,
    /// the clearance below the safe top, and off every inflated obstacle,
    /// which they may touch.
    private static func isClear(_ frame: CGRect, _ inputs: Inputs) -> Bool {
        guard hasFiniteBounds(frame) else {
            return false
        }
        let covered = pixelsCovered(by: frame, scale: inputs.displayScale, gridOrigin: inputs.pixelGridOrigin)
        let clearance = NowPlayingSoundLabLayout.openPanelClearance
        let obstacles = ([inputs.moreFrame] + inputs.occlusions).map { $0.insetBy(dx: -clearance, dy: -clearance) }
        guard hasFiniteBounds(covered), obstacles.allSatisfy(Self.hasFiniteBounds) else {
            return false
        }
        return covered.minX >= inputs.contentSpan.lowerBound
            && covered.maxX <= inputs.contentSpan.upperBound
            && inputs.viewport.contains(covered)
            && covered.minY >= inputs.safeTop + clearance
            && !obstacles.contains { NowPlayingCardGeometry.overlaps($0, covered) }
    }

    private static func hasFiniteBounds(_ rect: CGRect) -> Bool {
        rect.size.width >= 0
            && rect.size.height >= 0
            && [
                rect.origin.x, rect.origin.y,
                rect.size.width, rect.size.height,
                rect.minX, rect.maxX, rect.minY, rect.maxY
            ].allSatisfy { $0.isFinite }
    }

    /// An edge within this many pixels of a pixel boundary counts as on it,
    /// so floating-point noise in a measured coordinate (92⅓ × 3 landing at
    /// 276.99999999999994) cannot cost the panel a pixel pair. It permits an
    /// overhang of at most 0.001 px, a third of a thousandth of a point at
    /// 3x; anything past it rounds outward.
    fileprivate static let pixelTolerance: CGFloat = 0.001

    private static func pixelsCovered(by frame: CGRect, scale: CGFloat, gridOrigin: CGPoint) -> CGRect {
        func outward(_ value: CGFloat, from origin: CGFloat, rule: FloatingPointRoundingRule) -> CGFloat {
            let pixels = (value - origin) * scale
            let nudged = rule == .down ? pixels + pixelTolerance : pixels - pixelTolerance
            return origin + nudged.rounded(rule) / scale
        }
        let minX = outward(frame.minX, from: gridOrigin.x, rule: .down)
        let minY = outward(frame.minY, from: gridOrigin.y, rule: .down)
        let maxX = outward(frame.maxX, from: gridOrigin.x, rule: .up)
        let maxY = outward(frame.maxY, from: gridOrigin.y, rule: .up)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
