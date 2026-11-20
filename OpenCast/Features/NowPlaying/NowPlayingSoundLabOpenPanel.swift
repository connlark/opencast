import SwiftUI

/// Card-local and leading-relative throughout, so a right-to-left card resolves the same.
nonisolated struct NowPlayingSoundLabOpenPanel: Equatable {
    enum Mode: Equatable {
        case legacy
        case headed
        case headingless
    }

    struct Inputs {
        let square: CGRect
        let contentSpan: ClosedRange<CGFloat>
        let viewport: CGRect
        let safeTop: CGFloat
        let moreFrame: CGRect
        let occlusions: [CGRect]
        let displayScale: CGFloat
        /// A corner of the physical pixel grid, card-local.
        let pixelGridOrigin: CGPoint
        let rowCount: Int
        let isAccessibilitySize: Bool
        let paddedHeadingHeight: CGFloat
    }

    /// Nothing the artwork does may change this. The square is measured in `coordinateSpaceName`.
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

        /// The stack is centred on the square, so its span is too.
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

    struct TitledRows: Equatable {
        let rowHeight: CGFloat
        let headingGap: CGFloat?
        let rowGap: CGFloat
        /// Split equally above and below the heading and the rows.
        let verticalRemainder: CGFloat

        var rowMetrics: NowPlayingSoundLabLayout.RowMetrics {
            NowPlayingSoundLabLayout.RowMetrics(
                rowHeight: rowHeight,
                rowSpacing: rowGap,
                showsHeader: headingGap != nil
            )
        }
    }

    /// Leaves out the square's position and the pixel grid's origin, so a panel moves with its
    /// square without being resolved again; never use `CardContext` itself.
    struct ShapeKey: Equatable {
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

        /// Exact, but the side and the heading may differ from the kept values by a pixel.
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

    enum Disposition: Equatable {
        case keep
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
    let frame: CGRect
    let titledRows: TitledRows?

    static func isEligible(side: CGFloat, isAccessibilitySize: Bool) -> Bool {
        !isAccessibilitySize
            && NowPlayingSoundLabLayout.showsInline(panelSide: side)
            && NowPlayingSoundLabLayout.collapsesToIconOnly(
                rowAreaWidth: NowPlayingSoundLabLayout(panelWidth: side).rowAreaWidth,
                isAccessibilitySize: false
            )
    }

    static func legacy(side: CGFloat) -> Self {
        Self(mode: .legacy, frame: CGRect(x: 0, y: 0, width: side, height: side), titledRows: nil)
    }

    /// In the square's own coordinates.
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

    private static func openedGap(room: CGFloat, gaps: Int) -> CGFloat {
        typealias Layout = NowPlayingSoundLabLayout
        guard gaps > 0 else {
            return Layout.titledRowSpacing
        }
        return min(Layout.maximumCompactRowSpacing, max(Layout.titledRowSpacing, room / CGFloat(gaps)))
    }

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

    /// An edge this close to a pixel boundary counts as on it, so floating-point noise
    /// (92⅓ × 3 = 276.99999999999994) cannot cost the panel a pixel pair.
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
