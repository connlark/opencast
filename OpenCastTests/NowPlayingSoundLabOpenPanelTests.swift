import CoreGraphics
import SwiftUI
import Testing
@testable import OpenCast

/// The resolver at the fixtures. The Closed card's square and heading are the
/// README's: the measured-row 156.33 pt square centred in the 24…442 stack, a
/// complete padded heading of 25 pt.
@Suite("Sound Lab open panel")
struct NowPlayingSoundLabOpenPanelTests {
    typealias Layout = NowPlayingSoundLabLayout
    typealias OpenPanel = NowPlayingSoundLabOpenPanel

    static let heading: CGFloat = 25
    static let closedSide: CGFloat = 156.33
    static let closedTop: CGFloat = 92

    /// The square of `side` over the Closed stack's centre.
    static func closedSquare(side: CGFloat = closedSide, top: CGFloat = closedTop) -> CGRect {
        CGRect(x: 233 - side / 2, y: top, width: side, height: side)
    }

    static func closedInputs(
        square: CGRect = closedSquare(),
        viewport: CGRect = CGRect(x: 0, y: 0, width: 466, height: 678),
        occlusions: [CGRect] = NowPlayingCardGeometryTests.closedOcclusions,
        displayScale: CGFloat = 3,
        pixelGridOrigin: CGPoint = .zero,
        rowCount: Int = 3,
        isAccessibilitySize: Bool = false,
        paddedHeadingHeight: CGFloat = heading
    ) -> OpenPanel.Inputs {
        let geometry = NowPlayingCardGeometryTests.closed(occlusions: NowPlayingCardGeometryTests.closedOcclusions)
        return OpenPanel.Inputs(
            square: square,
            contentSpan: 24...442,
            viewport: viewport,
            safeTop: geometry.contentInsets.top,
            moreFrame: CGRect(origin: geometry.moreOrigin, size: CGSize(width: 44, height: 44)),
            occlusions: occlusions,
            displayScale: displayScale,
            pixelGridOrigin: pixelGridOrigin,
            rowCount: rowCount,
            isAccessibilitySize: isAccessibilitySize,
            paddedHeadingHeight: paddedHeadingHeight
        )
    }

    /// A card as wide as the cap needs, nothing in the way but what a test
    /// adds, for the rule's arithmetic away from any device's numbers.
    static func openInputs(
        side: CGFloat,
        top: CGFloat = 400,
        paddedHeadingHeight: CGFloat = heading,
        rowCount: Int = 3
    ) -> OpenPanel.Inputs {
        OpenPanel.Inputs(
            square: CGRect(x: 300 - side / 2, y: top, width: side, height: side),
            contentSpan: 0...600,
            viewport: CGRect(x: 0, y: 0, width: 600, height: 1000),
            safeTop: 0,
            moreFrame: CGRect(x: 0, y: 0, width: 44, height: 44),
            occlusions: [],
            displayScale: 3,
            pixelGridOrigin: .zero,
            rowCount: rowCount,
            isAccessibilitySize: false,
            paddedHeadingHeight: paddedHeadingHeight
        )
    }

    static func isNear(_ a: CGFloat, _ b: CGFloat, within tolerance: CGFloat = 0.001) -> Bool {
        abs(a - b) <= tolerance
    }

    // MARK: The Closed card

    @Test("Closed at L: the heading and three rows at 282 × 191.74, the top 56.59, the bottom on the square's")
    func closedAtLarge() throws {
        let panel = OpenPanel(Self.closedInputs())
        let rows = try #require(panel.titledRows)

        #expect(panel.mode == .headed)
        #expect(Self.isNear(panel.frame.width, 282))
        #expect(Self.isNear(panel.frame.minX, 92))
        #expect(Self.isNear(panel.frame.maxX, 374))
        #expect(Self.isNear(panel.frame.height, 191.74))
        #expect(Self.isNear(panel.frame.minY, 56.59))
        #expect(Self.isNear(panel.frame.maxY, Self.closedSquare().maxY))
        #expect(Self.isNear(panel.frame.midX, Self.closedSquare().midX))

        #expect(rows.rowHeight == Layout.compactRowHeight)
        #expect(rows.headingGap == Layout.titledRowSpacing)
        #expect(rows.rowGap == Layout.titledRowSpacing)
        #expect(Self.isNear(rows.verticalRemainder, 0))

        let layout = Layout(panelWidth: panel.frame.width)
        #expect(Self.isNear(layout.rowAreaWidth, 217.37))
        #expect(Self.isNear(layout.protectedLeadingSpace, 54.76))
        #expect(Self.isNear(layout.contentInset, 9.87))
    }

    @Test("Two rows need less than the square, so the square's height stands and the gaps open")
    func closedWithTwoRows() throws {
        let panel = OpenPanel(Self.closedInputs(rowCount: 2))
        let rows = try #require(panel.titledRows)
        let inset = Layout(panelWidth: 282).contentInset

        #expect(panel.mode == .headed)
        #expect(Self.isNear(panel.frame.width, 282))
        #expect(Self.isNear(panel.frame.height, Self.closedSide))
        #expect(Self.isNear(panel.frame.minY, Self.closedTop))
        let gap = (Self.closedSide - Self.heading - 2 * Layout.compactRowHeight - 2 * inset) / 2
        #expect(Self.isNear(try #require(rows.headingGap), gap))
        #expect(Self.isNear(rows.rowGap, gap))
        #expect(Self.isNear(rows.verticalRemainder, 0))
    }

    // MARK: Item 2, the early return

    /// The exact side at which today's row area reaches the title threshold,
    /// and a step either side of it: far above the arithmetic's rounding
    /// error, far below any side the card can produce.
    static let thresholdSide = CGFloat(206) / 0.785
    static let thresholdStep: CGFloat = 1e-9

    @Test("The production predicate turns at 206 / 0.785, and eligibility with it")
    func thresholdFromThePredicate() {
        let below = Self.thresholdSide - Self.thresholdStep
        let above = Self.thresholdSide + Self.thresholdStep
        func hasTitles(_ side: CGFloat) -> Bool {
            !Layout.collapsesToIconOnly(rowAreaWidth: Layout(panelWidth: side).rowAreaWidth, isAccessibilitySize: false)
        }
        #expect(!hasTitles(below))
        #expect(hasTitles(above))
        #expect(OpenPanel.isEligible(side: below, isAccessibilitySize: false))
        #expect(!OpenPanel.isEligible(side: above, isAccessibilitySize: false))
    }

    @Test(
        "Legacy returns early with the square, whatever the card allows",
        arguments: [
            (side: 64.0, isAccessibility: false),
            (side: 153.5, isAccessibility: false),
            (side: 156.33, isAccessibility: true),
            (side: 166.92, isAccessibility: true),
            (side: 214.24, isAccessibility: true),
            (side: 280.8, isAccessibility: false),
            (side: 337.0, isAccessibility: false)
        ]
    )
    func legacyEarlyReturn(side: Double, isAccessibility: Bool) {
        let open = Self.openInputs(side: CGFloat(side))
        let panel = OpenPanel(OpenPanel.Inputs(
            square: open.square,
            contentSpan: open.contentSpan,
            viewport: open.viewport,
            safeTop: open.safeTop,
            moreFrame: open.moreFrame,
            occlusions: open.occlusions,
            displayScale: open.displayScale,
            pixelGridOrigin: open.pixelGridOrigin,
            rowCount: open.rowCount,
            isAccessibilitySize: isAccessibility,
            paddedHeadingHeight: open.paddedHeadingHeight
        ))
        #expect(panel.mode == .legacy)
        #expect(panel.frame == open.square)
        #expect(panel.titledRows == nil)
    }

    @Test("Either side of the exact threshold: titled just below it, the square from it up")
    func thresholdResolves() {
        let below = OpenPanel(Self.openInputs(side: Self.thresholdSide - Self.thresholdStep))
        #expect(below.mode == .headed)
        #expect(below.frame.width > below.frame.height)
        let above = OpenPanel(Self.openInputs(side: Self.thresholdSide + Self.thresholdStep))
        #expect(above.mode == .legacy)
    }

    // MARK: Item 3, the clearance

    @Test("A band too narrow for the titles falls to the square, and the square alone needs no clearance")
    func bandTooNarrow() {
        // An obstacle whose inflated edge leaves a half-width under the
        // narrowest titled width's.
        let halfWidth = Layout.titledMinimumWidth / 2 - 1
        let obstacle = CGRect(
            x: 233 + halfWidth + Layout.openPanelClearance,
            y: 0,
            width: 40,
            height: 300
        )
        let panel = OpenPanel(Self.closedInputs(occlusions: [obstacle]))
        #expect(panel.mode == .legacy)
        #expect(panel.frame == Self.closedSquare())
    }

    @Test("An obstacle over the square's centre leaves no candidate")
    func obstacleOverTheCentre() {
        let square = Self.closedSquare()
        let obstacle = CGRect(x: square.midX, y: square.midY, width: 0, height: 0)
        #expect(OpenPanel(Self.closedInputs(occlusions: [obstacle])).mode == .legacy)
    }

    @Test("An obstacle one point outside the vertical extent narrows nothing; one point inside it does")
    func obstacleAtTheVerticalExtent() {
        // At the Closed card's left edge of the top row's band, across the
        // panel's whole width.
        let free = OpenPanel(Self.closedInputs(occlusions: []))
        let clearance = Layout.openPanelClearance
        func obstacle(inflatedBottom: CGFloat) -> CGRect {
            CGRect(x: 300, y: 0, width: 20, height: inflatedBottom - clearance)
        }
        let outside = OpenPanel(Self.closedInputs(occlusions: [obstacle(inflatedBottom: free.frame.minY - 1)]))
        #expect(outside == free)

        let inside = OpenPanel(Self.closedInputs(occlusions: [obstacle(inflatedBottom: free.frame.minY + 1)]))
        #expect(inside != free)
    }

    @Test("A panel may touch an inflated obstacle: the cluster's edge less the clearance is the panel's edge")
    func touchingIsAllowed() {
        let panel = OpenPanel(Self.closedInputs())
        let cluster = NowPlayingCardGeometryTests.closedOcclusions[1]
        #expect(Self.isNear(panel.frame.maxX, cluster.minX - Layout.openPanelClearance))
    }

    @Test("No room above: the heading gives way only where the square holds the rows, at 154 and 156.33 it cannot")
    func noRoomAbove() throws {
        let ceiling = CGRect(x: 0, y: 0, width: 466, height: 84 - Layout.openPanelClearance)

        for side in [154.0, Self.closedSide] {
            let panel = OpenPanel(Self.closedInputs(
                square: Self.closedSquare(side: side),
                occlusions: [ceiling]
            ))
            #expect(panel.mode == .legacy, "side \(side)")
        }

        // The three compact rows at their tightest at this width, plus a
        // little: the headed need is taller, and the ceiling refuses it.
        let width: CGFloat = 282
        let side = CGFloat(3) * Layout.compactRowHeight + 2 * Layout.titledRowSpacing
            + 2 * Layout(panelWidth: width).contentInset + 1
        let square = Self.closedSquare(side: side)
        let tall = CGRect(x: 0, y: 0, width: 466, height: square.minY - 1 - Layout.openPanelClearance)
        let panel = OpenPanel(Self.closedInputs(square: square, occlusions: [tall, NowPlayingCardGeometryTests.closedOcclusions[1]]))
        let rows = try #require(panel.titledRows)
        #expect(panel.mode == .headingless)
        #expect(Self.isNear(panel.frame.width, width))
        #expect(Self.isNear(panel.frame.minY, square.minY))
        #expect(Self.isNear(panel.frame.height, side))
        #expect(rows.headingGap == nil)
        #expect(rows.rowHeight == Layout.compactRowHeight)
        #expect(Self.isNear(rows.rowGap, Layout.titledRowSpacing + 0.5))
        #expect(Self.isNear(rows.verticalRemainder, 0))
    }

    /// How far the narrowest titled panel rises above the Closed square: a
    /// narrower panel has smaller insets, so it can clear what a wider one
    /// cannot.
    static var narrowestRise: CGFloat {
        let width = (Layout.titledMinimumWidth * 3).rounded(.up) / 3
        let inset = Layout(panelWidth: width).contentInset
        return heading + 3 * Layout.compactRowHeight + 3 * Layout.titledRowSpacing + 2 * inset - closedSide
    }

    @Test("Inside the clipping viewport: a viewport top just under the panel narrows it, one under the narrowest refuses it")
    func viewport() {
        let free = OpenPanel(Self.closedInputs())
        let square = Self.closedSquare()

        let narrowed = OpenPanel(Self.closedInputs(
            viewport: CGRect(x: 0, y: free.frame.minY + 1, width: 466, height: 600)
        ))
        #expect(narrowed.mode == .headed)
        #expect(narrowed.frame.width < free.frame.width)
        #expect(narrowed.frame.minY >= free.frame.minY + 1)

        let top = square.minY - Self.narrowestRise + 1
        let refused = OpenPanel(Self.closedInputs(viewport: CGRect(x: 0, y: top, width: 466, height: 600)))
        #expect(refused.mode == .legacy)
    }

    @Test("The clearance below the safe top: a square that rises past it narrows the panel, then gives way to the square")
    func safeTop() {
        let free = OpenPanel(Self.closedInputs())
        let clearance = Layout.openPanelClearance
        let rise = free.frame.height - Self.closedSide

        let clear = OpenPanel(Self.closedInputs(square: Self.closedSquare(top: rise + clearance + 1)))
        #expect(clear.mode == .headed)
        #expect(Self.isNear(clear.frame.width, free.frame.width))

        let narrowed = OpenPanel(Self.closedInputs(square: Self.closedSquare(top: rise + clearance - 0.5)))
        #expect(narrowed.mode == .headed)
        #expect(narrowed.frame.width < free.frame.width)
        #expect(narrowed.frame.minY >= clearance)

        let refused = OpenPanel(Self.closedInputs(square: Self.closedSquare(top: Self.narrowestRise + clearance - 1)))
        #expect(refused.mode == .legacy)
    }

    @Test("A wider band never narrows the panel, and the cap ends it")
    func monotonicInTheBand() {
        var previous: CGFloat = 0
        for edge in stride(from: CGFloat(340), through: 470, by: 0.5) {
            let obstacle = CGRect(x: edge, y: 0, width: 200, height: 200)
            let panel = OpenPanel(Self.closedInputs(occlusions: [obstacle]))
            let width = panel.mode == .legacy ? 0 : panel.frame.width
            #expect(width >= previous, "edge \(edge)")
            previous = width
        }
        #expect(Self.isNear(previous, Self.capWidth(scale: 3)))
    }

    // MARK: Item 5, the height and the gaps

    @Test("The open height never rises to widen a gap: the compact tier's height is the square or the tightest stack")
    func compactHeightIsUnique() throws {
        // A square just taller than the tightest stack keeps its height.
        let panel = OpenPanel(Self.openInputs(side: 200))
        let rows = try #require(panel.titledRows)
        let inset = Layout(panelWidth: panel.frame.width).contentInset
        #expect(panel.frame.height == 200)
        let gap = (200 - Self.heading - 3 * Layout.compactRowHeight - 2 * inset) / 3
        #expect(Self.isNear(rows.rowGap, gap))
        #expect(rows.headingGap == rows.rowGap)
        #expect(Self.isNear(rows.verticalRemainder, 0))
    }

    @Test("A roomy square's gaps stop at the compact maximum and the rest splits around the stack")
    func compactGapsStopAtTheMaximum() throws {
        let side = CGFloat(240)
        let panel = OpenPanel(Self.openInputs(side: side))
        let rows = try #require(panel.titledRows)
        let inset = Layout(panelWidth: panel.frame.width).contentInset
        #expect(rows.rowGap == Layout.maximumCompactRowSpacing)
        #expect(rows.headingGap == Layout.maximumCompactRowSpacing)
        let expected = side - Self.heading - 2 * inset - 3 * (Layout.compactRowHeight + Layout.maximumCompactRowSpacing)
        #expect(Self.isNear(rows.verticalRemainder, expected))
        #expect(expected > 0)
    }

    @Test(
        "Open heights just below, at and above 250 pt: compact below it, today's row metrics from it up",
        arguments: [(side: 249.99, rowHeight: 44.0), (side: 250.0, rowHeight: 56.0), (side: 250.01, rowHeight: 56.0)]
    )
    func tierBoundaryFromTheSquare(side: Double, rowHeight: Double) throws {
        let side = CGFloat(side)
        let rowHeight = CGFloat(rowHeight)
        let panel = OpenPanel(Self.openInputs(side: side))
        let rows = try #require(panel.titledRows)
        let inset = Layout(panelWidth: panel.frame.width).contentInset

        #expect(panel.mode == .headed)
        #expect(panel.frame.height == side)
        #expect(rows.rowHeight == rowHeight)
        let gap: CGFloat = rowHeight == 44 ? Layout.maximumCompactRowSpacing : Layout.titledRowSpacing
        #expect(rows.rowGap == gap)
        #expect(Self.isNear(rows.verticalRemainder, side - Self.heading - 2 * inset - 3 * (rowHeight + gap)))
    }

    @Test("A tall heading carries the open height past 250 pt: the smallest height holding today's rows and gaps")
    func tierBoundaryFromTheHeading() throws {
        let inset = Layout(panelWidth: Self.capWidth(scale: 3)).contentInset
        let compactNeed = 3 * Layout.compactRowHeight + 3 * Layout.titledRowSpacing + 2 * inset
        let tierNeed = 3 * Layout.controlRowHeight + 3 * Layout.titledRowSpacing + 2 * inset

        // The compact need just reaches 250, so the height is the tier's.
        let reaching = OpenPanel(Self.openInputs(side: 160, paddedHeadingHeight: 250 - compactNeed))
        #expect(reaching.titledRows?.rowHeight == Layout.controlRowHeight)
        #expect(Self.isNear(reaching.frame.height, 250 - compactNeed + tierNeed))

        // Just short of it the compact rows stand, at the compact height.
        let short = OpenPanel(Self.openInputs(side: 160, paddedHeadingHeight: 249 - compactNeed))
        #expect(short.titledRows?.rowHeight == Layout.compactRowHeight)
        #expect(Self.isNear(short.frame.height, 249))

        // Past 290 pt today's gaps are 7, and the height holds those.
        let roomy = OpenPanel(Self.openInputs(side: 160, paddedHeadingHeight: 290 - tierNeed + 1))
        #expect(roomy.titledRows?.rowGap == 7)
        #expect(Self.isNear(roomy.frame.height, 290 - tierNeed + 1 + tierNeed + 3 * 2))
        #expect(Self.isNear(try #require(roomy.titledRows).verticalRemainder, 0))
    }

    // MARK: Other cards

    @Test("The pinned iPhone with a failure block, 212.8 pt: the square's height, the width up to the cap")
    func pinnedIPhoneFailure() throws {
        let geometry = NowPlayingCardGeometryTests.pinnedIPhone()
        let side: CGFloat = 212.8
        let square = CGRect(x: 201 - side / 2, y: 150, width: side, height: side)
        let panel = OpenPanel(OpenPanel.Inputs(
            square: square,
            contentSpan: 24...378,
            viewport: CGRect(origin: .zero, size: NowPlayingCardGeometryTests.iPhoneWindow),
            safeTop: geometry.contentInsets.top,
            moreFrame: CGRect(origin: geometry.moreOrigin, size: CGSize(width: 44, height: 44)),
            occlusions: geometry.occlusions,
            displayScale: 3,
            pixelGridOrigin: .zero,
            rowCount: 3,
            isAccessibilitySize: false,
            paddedHeadingHeight: Self.heading
        ))
        let rows = try #require(panel.titledRows)
        let inset = Layout(panelWidth: panel.frame.width).contentInset

        #expect(panel.mode == .headed)
        #expect(Self.isNear(panel.frame.width, Self.capWidth(scale: 3)))
        #expect(panel.frame.height == side)
        #expect(panel.frame.minY == 150)
        #expect(Self.isNear(rows.rowGap, (side - Self.heading - 3 * Layout.compactRowHeight - 2 * inset) / 3))
        #expect(Self.isNear(panel.frame.minX, 49.1666666666667))
        #expect(Self.isNear(panel.frame.width, 303.6666666666667))
        #expect(Self.isNear(rows.rowGap, 11.5144444444444))
        #expect(Self.isNear(rows.verticalRemainder, 0))
    }

    @Test("Laptop, 179.5 pt at y 178: the rise stays in the media viewport, below More")
    func laptop() throws {
        let geometry = NowPlayingCardGeometry(
            allocation: CGRect(origin: .zero, size: NowPlayingCardGeometryTests.innerPortraitWindow),
            windowSize: NowPlayingCardGeometryTests.innerPortraitWindow,
            safeAreaInsets: NowPlayingCardGeometryTests.innerPortraitInsets,
            isAccessibilitySize: false,
            pose: .foldedHorizontal(band: NowPlayingCardGeometryTests.laptopBand),
            occlusions: [NowPlayingCardGeometryTests.innerPortraitCluster]
        )
        let side: CGFloat = 179.5
        let centre: CGFloat = 669.0 / 2
        let square = CGRect(x: centre - side / 2, y: 178, width: side, height: side)
        let panel = OpenPanel(OpenPanel.Inputs(
            square: square,
            contentSpan: (centre - 250)...(centre + 250),
            viewport: CGRect(x: 0, y: 0, width: 669, height: 455.5),
            safeTop: geometry.contentInsets.top,
            moreFrame: CGRect(origin: geometry.moreOrigin, size: CGSize(width: 44, height: 44)),
            occlusions: geometry.occlusions,
            displayScale: 3,
            pixelGridOrigin: .zero,
            rowCount: 3,
            isAccessibilitySize: false,
            paddedHeadingHeight: Self.heading
        ))

        #expect(panel.mode == .headed)
        #expect(Self.isNear(panel.frame.width, Self.capWidth(scale: 3)))
        #expect(Self.isNear(panel.frame.maxY, square.maxY))
        #expect(panel.frame.height > side)
        let more = CGRect(origin: geometry.moreOrigin, size: CGSize(width: 44, height: 44))
        #expect(panel.frame.minY >= more.maxY + Layout.openPanelClearance)
        #expect(Self.isNear(panel.frame.minX, 182.6666666666667))
        #expect(Self.isNear(panel.frame.width, 303.6666666666667))
        #expect(Self.isNear(panel.frame.height, 193.2566666666667))
        #expect(Self.isNear(panel.frame.minY, 164.2433333333333))
        let rows = try #require(panel.titledRows)
        #expect(Self.isNear(rows.rowHeight, 44))
        #expect(Self.isNear(rows.rowGap, 5))
        #expect(Self.isNear(rows.verticalRemainder, 0))
    }

    @Test("A right-to-left card's leading-relative inputs resolve as the left-to-right card's do")
    func rightToLeft() {
        // Mirrored into leading-relative coordinates a right-to-left card is
        // the same card: More is at its leading side and the cluster at its
        // trailing one, and nothing in the resolver reads a direction.
        let cluster = NowPlayingCardGeometryTests.closedOcclusions[1]
        let physical = CGRect(x: 466 - cluster.maxX, y: cluster.minY, width: cluster.width, height: cluster.height)
        let mirrored = CGRect(x: 466 - physical.maxX, y: physical.minY, width: physical.width, height: physical.height)
        #expect(mirrored == cluster)
        let panel = OpenPanel(Self.closedInputs(occlusions: [mirrored]))
        #expect(panel.mode == .headed)
        #expect(Self.isNear(panel.frame.minX, 92))
        #expect(Self.isNear(panel.frame.maxX, 374))
        #expect(Self.isNear(panel.frame.minY, 56.59))
        #expect(Self.isNear(panel.frame.height, 191.74))
    }

    @Test("A square scrolled upward: the panel follows it while it clears, then the square takes over")
    func scrolledUpward() {
        let rest = OpenPanel(Self.closedInputs())
        let scrolled = OpenPanel(Self.closedInputs(square: Self.closedSquare(top: Self.closedTop - 40)))
        #expect(scrolled.mode == .headed)
        #expect(Self.isNear(scrolled.frame.minY, rest.frame.minY - 40))
        #expect(Self.isNear(scrolled.frame.width, rest.frame.width))

        let square = Self.closedSquare(top: Self.closedTop - 80)
        let tooHigh = OpenPanel(Self.closedInputs(square: square))
        #expect(tooHigh.mode == .legacy)
        #expect(tooHigh.frame == square)
    }

    // MARK: The pixel grid

    static func capWidth(scale: CGFloat) -> CGFloat {
        (Layout.titledReferenceWidth * scale).rounded(.up) / scale
    }

    @Test("The cap is the exact reference width rounded up to the display grid", arguments: [2.0, 3.0])
    func capRoundsUp(scale: Double) throws {
        let scale = CGFloat(scale)
        let panel = OpenPanel(OpenPanel.Inputs(
            square: CGRect(x: 400 - 100, y: 400, width: 200, height: 200),
            contentSpan: 0...800,
            viewport: CGRect(x: 0, y: 0, width: 800, height: 1000),
            safeTop: 0,
            moreFrame: CGRect(x: 0, y: 0, width: 44, height: 44),
            occlusions: [],
            displayScale: scale,
            pixelGridOrigin: .zero,
            rowCount: 3,
            isAccessibilitySize: false,
            paddedHeadingHeight: Self.heading
        ))
        let pixels = panel.frame.width * scale
        #expect(Self.isNear(pixels, pixels.rounded()))
        #expect(panel.frame.width >= Layout.titledReferenceWidth)
        #expect(panel.frame.width - Layout.titledReferenceWidth < 1 / scale)
    }

    struct PixelFixture: Sendable {
        let scale: CGFloat
        let originX: CGFloat
        let width: CGFloat
        let maxX: CGFloat
    }

    static let pixelFixtures = [
        // A whole-point origin: the cluster's inflated edge is a pixel edge.
        PixelFixture(scale: 2, originX: 0, width: 282, maxX: 374),
        PixelFixture(scale: 3, originX: 0, width: 282, maxX: 374),
        // A fractional origin moves every pixel edge, and the last one
        // before the cluster with it.
        PixelFixture(scale: 2, originX: 0.25, width: 281.5, maxX: 373.75),
        PixelFixture(scale: 3, originX: 1.0 / 6, width: 281 + 2.0 / 3, maxX: 373 + 5.0 / 6)
    ]

    @Test(
        "Outward pixel coverage from the grid's origin keeps the panel off the obstacle, centred on the square",
        arguments: pixelFixtures
    )
    func pixelPlacement(fixture: PixelFixture) {
        let panel = OpenPanel(Self.closedInputs(
            displayScale: fixture.scale,
            pixelGridOrigin: CGPoint(x: fixture.originX, y: 0)
        ))
        #expect(panel.mode == .headed)
        #expect(Self.isNear(panel.frame.width, fixture.width))
        #expect(Self.isNear(panel.frame.maxX, fixture.maxX))
        #expect(Self.isNear(panel.frame.midX, Self.closedSquare().midX))
    }

    @Test("An overhang inside the tolerance keeps the width: 0.0001 pt past the cluster's edge still ends on its pixel")
    func overhangInsideTheTolerance() {
        let panel = OpenPanel(Self.closedInputs(square: Self.closedSquare().offsetBy(dx: 0.0001, dy: 0)))
        #expect(panel.mode == .headed)
        #expect(Self.isNear(panel.frame.width, 282))
    }

    @Test("A real overhang rounds outward: 0.01 pt past the cluster's edge costs a pixel pair")
    func overhangPastTheTolerance() {
        let panel = OpenPanel(Self.closedInputs(square: Self.closedSquare().offsetBy(dx: 0.01, dy: 0)))
        #expect(panel.mode == .headed)
        #expect(Self.isNear(panel.frame.width, 281 + 2.0 / 3))
        #expect((panel.frame.maxX * 3).rounded(.up) / 3 <= 374)
    }

    @Test(
        "A square carrying measurement noise resolves as the clean fixture does",
        arguments: [
            (dx: 1e-12, dy: 0.0),
            (dx: -1e-12, dy: 0.0),
            (dx: 0.0, dy: 1e-12),
            (dx: 0.0, dy: -1e-12),
            (dx: 1e-12, dy: -1e-12)
        ]
    )
    func measurementNoise(dx: Double, dy: Double) {
        let clean = OpenPanel(Self.closedInputs())
        let noisy = OpenPanel(Self.closedInputs(square: Self.closedSquare().offsetBy(dx: dx, dy: dy)))
        #expect(noisy.mode == clean.mode)
        #expect(noisy.frame.width == clean.frame.width)
        #expect(noisy.titledRows == clean.titledRows)
        #expect(Self.isNear(noisy.frame.minX, clean.frame.minX, within: 1e-9))
        #expect(Self.isNear(noisy.frame.minY, clean.frame.minY, within: 1e-9))
    }

    @Test("A candidate's covered pixels decide it: half a pixel past the obstacle's edge rounds out onto the next pixel")
    func coverageDecides() {
        // With the inflated edge a pixel short of 374, a width of 281.67
        // would end at 373.83, whose pixel ends at 374: refused, and 281.33,
        // ending on the edge, taken.
        let edge = CGFloat(374) - 1.0 / 3
        let panel = OpenPanel(Self.closedInputs(occlusions: [
            CGRect(x: edge + Layout.openPanelClearance, y: 0, width: 10, height: 300)
        ]))
        #expect(Self.isNear(panel.frame.maxX, edge))
        #expect(Self.isNear(panel.frame.width, 281.0 + 1.0 / 3))
        #expect(Self.isNear(panel.frame.midX, Self.closedSquare().midX))
    }

    @Test("Fractional logical edges are allowed: a centre that puts the cap's edges between pixels keeps the cap")
    func fractionalEdgesAreAllowed() {
        // Half the cap's pixels, plus the centre's, must land on a half pixel.
        let capIsOddInPixels = Int((Self.capWidth(scale: 3) * 3).rounded()) % 2 == 1
        let offset: CGFloat = capIsOddInPixels ? 0 : 1.0 / 6
        let open = Self.openInputs(side: 200)
        let centre = open.square.midX + offset
        let panel = OpenPanel(OpenPanel.Inputs(
            square: open.square.offsetBy(dx: offset, dy: 0),
            contentSpan: open.contentSpan,
            viewport: open.viewport,
            safeTop: open.safeTop,
            moreFrame: open.moreFrame,
            occlusions: open.occlusions,
            displayScale: open.displayScale,
            pixelGridOrigin: open.pixelGridOrigin,
            rowCount: open.rowCount,
            isAccessibilitySize: open.isAccessibilitySize,
            paddedHeadingHeight: open.paddedHeadingHeight
        ))
        #expect(Self.isNear(panel.frame.width, Self.capWidth(scale: 3)))
        #expect(Self.isNear(panel.frame.midX, centre))
        let edgePixels = panel.frame.minX * 3
        #expect(Self.isNear(abs(edgePixels - edgePixels.rounded()), 0.5))
    }

    // MARK: Malformed inputs

    /// The Closed inputs with one value replaced. Every case below would
    /// otherwise resolve headed.
    static func malformed(
        square: CGRect = closedSquare(),
        viewport: CGRect = CGRect(x: 0, y: 0, width: 466, height: 678),
        safeTop: CGFloat = 0,
        moreFrame: CGRect = CGRect(x: 20, y: 62, width: 44, height: 44),
        occlusions: [CGRect] = NowPlayingCardGeometryTests.closedOcclusions,
        displayScale: CGFloat = 3,
        pixelGridOrigin: CGPoint = .zero,
        rowCount: Int = 3,
        paddedHeadingHeight: CGFloat = heading
    ) -> OpenPanel.Inputs {
        OpenPanel.Inputs(
            square: square,
            contentSpan: 24...442,
            viewport: viewport,
            safeTop: safeTop,
            moreFrame: moreFrame,
            occlusions: occlusions,
            displayScale: displayScale,
            pixelGridOrigin: pixelGridOrigin,
            rowCount: rowCount,
            isAccessibilitySize: false,
            paddedHeadingHeight: paddedHeadingHeight
        )
    }

    @Test("The malformed-input helper's defaults are the Closed fixture")
    func malformedDefaultsResolve() {
        #expect(OpenPanel(Self.malformed()) == OpenPanel(Self.closedInputs()))
    }

    @Test("A row count of zero or less keeps the square", arguments: [0, -1, Int.min])
    func malformedRowCount(rowCount: Int) {
        let panel = OpenPanel(Self.malformed(rowCount: rowCount))
        #expect(panel.mode == .legacy)
        #expect(panel.frame == Self.closedSquare())
    }

    @Test(
        "A display scale that is not a positive finite number keeps the square",
        arguments: [0.0, -1.0, -3.0, Double.nan, Double.infinity, -Double.infinity]
    )
    func malformedScale(scale: Double) {
        let panel = OpenPanel(Self.malformed(displayScale: CGFloat(scale)))
        #expect(panel.mode == .legacy)
        #expect(panel.frame == Self.closedSquare())
    }

    @Test("A scale too large to count in pixels keeps the square")
    func scaleBeyondInt() {
        #expect(OpenPanel(Self.malformed(displayScale: .greatestFiniteMagnitude)).mode == .legacy)
    }

    @Test("A heading height that is not a non-negative finite number keeps the square", arguments: [Double.nan, Double.infinity, -1.0])
    func malformedHeading(height: Double) {
        #expect(OpenPanel(Self.malformed(paddedHeadingHeight: CGFloat(height))).mode == .legacy)
    }

    @Test("Non-finite geometry anywhere in the inputs keeps the square, and traps nothing")
    func malformedGeometry() {
        let notANumber = CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10)
        let unbounded = CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 10)
        let inputs = [
            Self.malformed(viewport: notANumber),
            Self.malformed(viewport: unbounded),
            Self.malformed(safeTop: .nan),
            Self.malformed(safeTop: .infinity),
            Self.malformed(moreFrame: notANumber),
            Self.malformed(moreFrame: unbounded),
            Self.malformed(occlusions: [notANumber]),
            Self.malformed(occlusions: [unbounded]),
            Self.malformed(pixelGridOrigin: CGPoint(x: CGFloat.nan, y: 0)),
            Self.malformed(pixelGridOrigin: CGPoint(x: 0, y: CGFloat.infinity))
        ]
        for input in inputs {
            #expect(OpenPanel(input).mode == .legacy)
        }
    }

    @Test("A square that is not a finite size is no square to open from")
    func malformedSquare() {
        let squares = [
            CGRect(x: 100, y: 92, width: CGFloat.nan, height: 156),
            CGRect(x: 100, y: 92, width: CGFloat.infinity, height: 156),
            CGRect(x: CGFloat.nan, y: 92, width: 156.33, height: 156.33),
            CGRect(x: 100, y: CGFloat.infinity, width: 156.33, height: 156.33)
        ]
        for square in squares {
            #expect(OpenPanel(Self.malformed(square: square)).mode == .legacy)
        }
    }
}
