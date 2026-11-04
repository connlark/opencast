import CoreGraphics
import SwiftUI
import Testing
@testable import OpenCast

/// The arrangement's shipping layout calculations with synthetic poses. The
/// inner display's windows, insets, status clusters and the 40 pt band at
/// 455.5 are the iPhone Duo simulator's (OBSERVED); a split's halves are what
/// the system's split arrangement gives along a fold (OBSERVED in Book: the
/// player 0–455, the pane 495–866, inside the safe rectangle) and evenly when
/// flat. Off-centre bands, right-to-left mirrors and straddling halves are
/// fixtures. The row heights are the measured ones the content-metrics
/// suite uses.
@MainActor
@Suite("Now Playing arrangement layouts")
struct NowPlayingArrangementLayoutTests {
    static let wideWindow = NowPlayingCardGeometryTests.innerLandscapeWindow
    static let wideInsets = NowPlayingCardGeometryTests.innerLandscapeInsets
    static let wideCluster = NowPlayingCardGeometryTests.innerLandscapeCluster
    static let bookBand = NowPlayingCardGeometryTests.bookBand
    static let tallWindow = NowPlayingCardGeometryTests.innerPortraitWindow
    static let tallInsets = NowPlayingCardGeometryTests.innerPortraitInsets
    static let tallCluster = NowPlayingCardGeometryTests.innerPortraitCluster
    static let laptopBand = NowPlayingCardGeometryTests.laptopBand

    static let titleBlock = NowPlayingContentMetricsTests.titleBlockAtLarge
    static let progressSection = NowPlayingContentMetricsTests.progressSectionAtLarge
    /// The transport and the utility row at L: the measured rows less the
    /// title block, the progress section and the three gaps between them.
    static let transportAndUtility = NowPlayingContentMetricsTests.rowsAtLarge - titleBlock - progressSection - 3 * 12
    /// The disclosure row as it renders, hosted and measured, and its gap.
    static var disclosureRow: CGFloat {
        measuredRowHeight() + 12
    }
    /// Laptop's controls at L: progress, transport, utility (two gaps) and the row.
    static var laptopControls: CGFloat {
        CGFloat(progressSection + 2 * 12 + transportAndUtility) + disclosureRow
    }

    static func hostedHeight(_ view: some View, width: CGFloat) -> CGFloat {
        UIHostingController(rootView: view)
            .sizeThatFits(in: CGSize(width: width, height: CGFloat.infinity))
            .height
    }

    static func measuredRowHeight(_ size: DynamicTypeSize = .large) -> CGFloat {
        hostedHeight(
            NowPlayingSecondaryDisclosureRow(selection: .transcript, isExpanded: false, action: {})
                .environment(\.dynamicTypeSize, size),
            width: 500
        )
    }

    static func measuredPickerHeight(_ size: DynamicTypeSize = .large) -> CGFloat {
        hostedHeight(
            NowPlayingSecondaryPanePicker(selection: .constant(.upNext))
                .environment(\.dynamicTypeSize, size),
            width: 340
        )
    }

    static func safeRect(_ window: CGSize, _ insets: EdgeInsets) -> CGRect {
        CGRect(
            x: insets.leading,
            y: insets.top,
            width: window.width - insets.leading - insets.trailing,
            height: window.height - insets.top - insets.bottom
        )
    }

    static func surface(
        window: CGSize = wideWindow,
        insets: EdgeInsets = wideInsets,
        pose: WindowPose,
        occlusions: [CGRect] = [wideCluster],
        isAccessibilitySize: Bool = false
    ) -> NowPlayingSurface {
        NowPlayingSurface(
            windowSize: window,
            safeAreaInsets: insets,
            pose: pose,
            occlusions: occlusions,
            isAccessibilitySize: isAccessibilitySize
        )
    }

    /// The shipping split: the player's and the pane's allocations.
    static func split(
        band: CGRect?,
        window: CGSize = wideWindow,
        insets: EdgeInsets = wideInsets
    ) throws -> (player: CGRect, pane: CGRect) {
        let allocations = NowPlayingAllocations(arrangement: .split(band: band), bounds: window, safeAreaInsets: insets)
        return (allocations.player, try #require(allocations.pane))
    }

    /// The widest default-type transport: two 76 pt skip buttons, the 96 pt
    /// play button and two 42 pt gaps.
    static let widestTransport: CGFloat = 76 + 42 + 96 + 42 + 76

    /// The player's content and controls in the window reader's space: the
    /// card inset by its content insets, the stack's column from the metrics,
    /// and More.
    struct PlayerFrames {
        let card: CGRect
        let content: CGRect
        let column: CGRect
        let more: CGRect
    }

    static func playerFrames(_ geometry: NowPlayingCardGeometry, rows: CGFloat? = nil) -> PlayerFrames {
        let card = geometry.cardFrame
        let insets = geometry.contentInsets
        let metrics = NowPlayingContentMetrics(
            containerSize: card.size,
            cardGeometry: geometry,
            dynamicTypeSize: .large,
            horizontalSizeClass: .regular,
            measurements: NowPlayingContentMeasurements(rowsHeight: rows)
        )
        return PlayerFrames(
            card: card,
            content: CGRect(
                x: card.minX + insets.leading,
                y: card.minY + insets.top,
                width: card.width - insets.leading - insets.trailing,
                height: card.height - insets.top - insets.bottom
            ),
            column: CGRect(
                x: card.minX + metrics.leadingPadding,
                y: card.minY + metrics.topContentPadding,
                width: metrics.contentWidth,
                height: card.height - metrics.topContentPadding - metrics.bottomContentPadding
            ),
            more: CGRect(
                origin: CGPoint(x: card.minX + geometry.moreOrigin.x, y: card.minY + geometry.moreOrigin.y),
                size: CGSize(width: NowPlayingCardGeometry.moreDiameter, height: NowPlayingCardGeometry.moreDiameter)
            )
        )
    }

    static func contains(_ outer: CGRect, _ inner: CGRect) -> Bool {
        inner.minX >= outer.minX - 0.001 && inner.maxX <= outer.maxX + 0.001
            && inner.minY >= outer.minY - 0.001 && inner.maxY <= outer.maxY + 0.001
    }

    // MARK: Book and the flat wide display

    @Test("Book: the player keeps the band's leading side and the pane its trailing side, both inside the safe rectangle")
    func bookOppositeSides() throws {
        let safe = Self.safeRect(Self.wideWindow, Self.wideInsets)
        let (playerAllocation, paneAllocation) = try Self.split(band: Self.bookBand)
        // The voted frames: the player 0–455.5, the pane 495.5–867, in the safe height.
        #expect(playerAllocation == CGRect(x: 0, y: 0, width: 455.5, height: 635))
        #expect(paneAllocation == CGRect(x: 495.5, y: 0, width: 371.5, height: 635))
        let surface = Self.surface(pose: .foldedVertical(band: Self.bookBand))

        let player = Self.playerFrames(surface.playerGeometry(allocation: playerAllocation))
        #expect(player.card == playerAllocation)
        #expect(player.column.maxX <= Self.bookBand.minX)
        #expect(player.more.maxX <= Self.bookBand.minX)
        #expect(Self.contains(safe, player.content))
        #expect(Self.contains(safe, player.column))
        #expect(Self.contains(safe, player.more))
        #expect(!NowPlayingCardGeometry.overlaps(player.more, Self.wideCluster))

        let pane = surface.paneGeometry(allocation: paneAllocation)
        #expect(pane.contentFrame.minX >= Self.bookBand.maxX)
        #expect(Self.contains(safe, pane.contentFrame))
        #expect(pane.contentInsets == EdgeInsets())
        #expect(!NowPlayingCardGeometry.overlaps(pane.contentFrame, Self.wideCluster))
    }

    @Test("Book, right to left: the leading side is the physical right, and the player and the pane still split on the band")
    func bookRightToLeft() throws {
        // A band at physical x 300–340 is reported mirrored, measured from the
        // leading (right) edge; the rail stays trailing (physically left).
        let width = Self.wideWindow.width
        let physicalBand = CGRect(x: 300, y: 0, width: 40, height: 669)
        let band = CGRect(x: width - physicalBand.maxX, y: 0, width: 40, height: 669)
        let safe = Self.safeRect(Self.wideWindow, Self.wideInsets)
        let (playerAllocation, paneAllocation) = try Self.split(band: band)
        let surface = Self.surface(pose: .foldedVertical(band: band))

        let player = Self.playerFrames(surface.playerGeometry(allocation: playerAllocation))
        let pane = surface.paneGeometry(allocation: paneAllocation)
        #expect(player.column.maxX <= band.minX)
        #expect(pane.contentFrame.minX >= band.maxX)
        #expect(Self.contains(safe, player.content))
        #expect(Self.contains(safe, pane.contentFrame))
        // Back in physical space: the player right of the band, the pane left.
        #expect(width - player.content.maxX >= physicalBand.maxX)
        #expect(width - pane.contentFrame.minX <= physicalBand.minX)
    }

    @Test("Book with an off-centre band: the player keeps the leading side while it holds the widest transport, each half on its side")
    func bookOffCentreBand() throws {
        let safe = Self.safeRect(Self.wideWindow, Self.wideInsets)
        for bandX in [420.0, 600.0, 700.0] {
            let band = CGRect(x: bandX, y: 0, width: 40, height: 669)
            let (playerAllocation, paneAllocation) = try Self.split(band: band)
            let surface = Self.surface(pose: .foldedVertical(band: band))
            let player = Self.playerFrames(surface.playerGeometry(allocation: playerAllocation))
            let pane = surface.paneGeometry(allocation: paneAllocation)
            #expect(playerAllocation.minX == safe.minX)
            #expect(player.column.maxX <= band.minX)
            #expect(player.more.maxX <= band.minX)
            #expect(player.column.width >= Self.widestTransport)
            #expect(pane.contentFrame.minX >= band.maxX)
            #expect(Self.contains(safe, player.column))
            #expect(Self.contains(safe, pane.contentFrame))
        }
    }

    @Test("A leading side too narrow for the transport gives the player the wider trailing side and the pane the leading one")
    func narrowLeadingSideSwaps() throws {
        let safe = Self.safeRect(Self.wideWindow, Self.wideInsets)
        let band = CGRect(x: 180, y: 0, width: 40, height: 669)
        let (playerAllocation, paneAllocation) = try Self.split(band: band)
        #expect(playerAllocation.minX == band.maxX)
        #expect(paneAllocation.maxX == band.minX)
        let surface = Self.surface(pose: .foldedVertical(band: band))
        let player = Self.playerFrames(surface.playerGeometry(allocation: playerAllocation))
        let pane = surface.paneGeometry(allocation: paneAllocation)
        #expect(player.column.minX >= band.maxX)
        #expect(player.column.width >= Self.widestTransport)
        #expect(pane.contentFrame.maxX <= band.minX)
        #expect(Self.contains(safe, player.column))
        #expect(Self.contains(safe, pane.contentFrame))
        // The minimum is the widest transport inside the regular card's paddings.
        #expect(NowPlayingAllocations.minimumPlayerWidth == Self.widestTransport + 72)
    }

    @Test("Card and the tall display give the player the whole surface and no pane beside it")
    func cardAndSingleAllocations() {
        for arrangement in [NowPlayingArrangement.card, .single(band: nil), .single(band: Self.laptopBand)] {
            let allocations = NowPlayingAllocations(
                arrangement: arrangement,
                bounds: Self.tallWindow,
                safeAreaInsets: Self.tallInsets
            )
            #expect(allocations.player == CGRect(origin: .zero, size: Self.tallWindow))
            #expect(allocations.pane == nil)
        }
    }

    @Test("A half that straddles the band is confined: the player to the leading side, the pane's content to the trailing side")
    func straddlingHalvesAreConfined() {
        let safe = Self.safeRect(Self.wideWindow, Self.wideInsets)
        let playerAllocation = CGRect(x: 0, y: 0, width: 475.5, height: safe.height)
        let paneAllocation = CGRect(x: 475.5, y: 0, width: safe.maxX - 475.5, height: safe.height)
        let surface = Self.surface(pose: .foldedVertical(band: Self.bookBand))

        let player = Self.playerFrames(surface.playerGeometry(allocation: playerAllocation))
        #expect(player.card == CGRect(x: 0, y: 0, width: Self.bookBand.minX, height: safe.height))
        #expect(player.column.maxX <= Self.bookBand.minX)

        let pane = surface.paneGeometry(allocation: paneAllocation)
        #expect(pane.contentInsets.leading == Self.bookBand.maxX - 475.5)
        #expect(pane.contentFrame.minX == Self.bookBand.maxX)

        // A player half wholly past the band's leading edge keeps its trailing side.
        let late = surface.playerGeometry(allocation: CGRect(x: 470, y: 0, width: 300, height: safe.height))
        #expect(late.cardFrame.minX == Self.bookBand.maxX)
    }

    @Test("Flat and wide: an even split keeps both allocations, their content and More inside the safe rectangle")
    func flatWideInsideTheSafeRectangle() throws {
        let safe = Self.safeRect(Self.wideWindow, Self.wideInsets)
        let half = safe.width / 2
        let (playerAllocation, paneAllocation) = try Self.split(band: nil)
        #expect(playerAllocation == CGRect(x: safe.minX, y: safe.minY, width: half, height: safe.height))
        #expect(paneAllocation == CGRect(x: safe.minX + half, y: safe.minY, width: half, height: safe.height))
        let surface = Self.surface(pose: .regularFlat)

        let player = Self.playerFrames(
            surface.playerGeometry(allocation: playerAllocation),
            rows: NowPlayingContentMetricsTests.rowsAtLarge
        )
        #expect(Self.contains(safe, player.content))
        #expect(Self.contains(safe, player.column))
        #expect(Self.contains(safe, player.more))
        let pane = surface.paneGeometry(allocation: paneAllocation)
        #expect(Self.contains(safe, pane.contentFrame))
        #expect(pane.contentFrame.maxX <= Self.wideCluster.minX)
    }

    @Test("Asymmetric insets apply once: a half reaching the window's edges is inset by exactly the part of the safe area it covers")
    func asymmetricInsetsApplyOnce() {
        let insets = EdgeInsets(top: 24, leading: 40, bottom: 34, trailing: 84)
        let surface = Self.surface(insets: insets, pose: .regularFlat, occlusions: [])
        let paneAllocation = CGRect(x: 500, y: 0, width: 451, height: 669)
        let pane = surface.paneGeometry(allocation: paneAllocation)
        #expect(pane.contentInsets == EdgeInsets(top: 24, leading: 0, bottom: 34, trailing: 84))
        #expect(pane.contentFrame == CGRect(x: 500, y: 24, width: 451.0 - 84, height: 669.0 - 24 - 34))

        let playerAllocation = CGRect(x: 0, y: 0, width: 500, height: 669)
        let player = surface.playerGeometry(allocation: playerAllocation)
        #expect(player.contentInsets == EdgeInsets(top: 24, leading: 40, bottom: 34, trailing: 0))

        // The same half already inside the safe rectangle takes no inset.
        let inside = surface.paneGeometry(allocation: CGRect(x: 500, y: 24, width: 367, height: 611))
        #expect(inside.contentInsets == EdgeInsets())
    }

    @Test("Occlusions over a half's top push the pane's picker and the player's controls below them; More leaves the covered corner")
    func occlusionsOverAHalf() {
        let cluster = CGRect(x: 700, y: 0, width: 84, height: 124)
        let surface = Self.surface(pose: .regularFlat, occlusions: [cluster])
        let pane = surface.paneGeometry(allocation: CGRect(x: 433.5, y: 0, width: 433.5, height: 635))
        #expect(pane.contentInsets.top == 124)
        #expect(!NowPlayingCardGeometry.overlaps(pane.contentFrame, cluster))

        // A region over the player half's top-trailing corner moves More to the leading corner.
        let corner = CGRect(x: 360, y: 0, width: 73.5, height: 70)
        let player = Self.surface(pose: .regularFlat, occlusions: [corner])
            .playerGeometry(allocation: CGRect(x: 0, y: 0, width: 433.5, height: 635))
        let frames = Self.playerFrames(player)
        #expect(player.moreIsLeading)
        #expect(!NowPlayingCardGeometry.overlaps(frames.more, corner))
        #expect(player.controlsMinY >= corner.maxY)
    }

    @Test("A non-zero origin is converted once: the pane's insets are its own, never the window's")
    func nonZeroOrigins() {
        let surface = Self.surface(pose: .foldedVertical(band: Self.bookBand))
        let pane = surface.paneGeometry(allocation: CGRect(x: 495.5, y: 0, width: 371.5, height: 635))
        #expect(pane.allocation.minX == 495.5)
        #expect(pane.contentInsets.leading == 0)
        #expect(pane.contentFrame.minX == 495.5)
    }

    // MARK: Laptop and the tall open display

    static func laptopLayout(
        titleBlock: CGFloat? = titleBlock,
        controls: CGFloat? = laptopControls,
        expandedPane: CGFloat = 0,
        isAccessibilitySize: Bool = false
    ) throws -> (layout: NowPlayingFoldedLayout, geometry: NowPlayingCardGeometry) {
        let surface = Self.surface(
            window: tallWindow,
            insets: tallInsets,
            pose: .foldedHorizontal(band: laptopBand),
            occlusions: [tallCluster],
            isAccessibilitySize: isAccessibilitySize
        )
        let geometry = surface.playerGeometry(allocation: CGRect(origin: .zero, size: tallWindow))
        let metrics = NowPlayingContentMetrics(
            containerSize: tallWindow,
            cardGeometry: geometry,
            dynamicTypeSize: isAccessibilitySize ? .accessibility4 : .large,
            horizontalSizeClass: .regular,
            measurements: NowPlayingContentMeasurements()
        )
        let fold = try #require(geometry.horizontalFold)
        let layout = NowPlayingFoldedLayout(
            cardHeight: tallWindow.height,
            fold: fold,
            cardGeometry: geometry,
            artworkUpperBound: metrics.artworkUpperBound,
            contentSpacing: metrics.contentSpacing,
            isAccessibilitySize: isAccessibilitySize,
            titleBlockHeight: titleBlock,
            controlsHeight: controls,
            expandedPaneHeight: expandedPane
        )
        return (layout, geometry)
    }

    @Test("Laptop at L: the complete media sits above the band and the complete controls, the row included, below it; both fit")
    func laptopFitsAroundTheBand() throws {
        let (layout, geometry) = try Self.laptopLayout()
        let band = Self.laptopBand
        #expect(geometry.cardFrame == CGRect(origin: .zero, size: Self.tallWindow))
        #expect(layout.mediaViewport == 0...band.minY)
        #expect(layout.controlsViewport == band.maxY...Self.tallWindow.height)

        let media = try #require(layout.mediaSpan)
        #expect(media.lowerBound >= Self.tallInsets.top)
        #expect(media.upperBound <= band.minY - NowPlayingCardGeometry.foldClearance + 0.001)
        let controls = try #require(layout.controlsSpan)
        #expect(controls.lowerBound >= band.maxY + NowPlayingCardGeometry.foldClearance)
        #expect(controls.upperBound <= Self.tallWindow.height - Self.tallInsets.bottom)
        #expect(!layout.mediaRequiresScrolling)
        #expect(!layout.controlsRequireScrolling)
        // The artwork gives way to the title block in the upper viewport.
        let expectedArtwork = band.minY - geometry.contentTopPadding - NowPlayingCardGeometry.foldClearance - Self.titleBlock - 12
        #expect(abs(layout.artworkSize - expectedArtwork) < 0.001)
        #expect(layout.artworkSize >= NowPlayingContentMetrics.minimumArtworkSize)
    }

    @Test("Laptop: More and the toasts sit in the upper viewport, clear of the status cluster and above the band")
    func laptopChromeAboveTheBand() throws {
        let (_, geometry) = try Self.laptopLayout()
        let more = CGRect(origin: geometry.moreOrigin, size: CGSize(width: 44, height: 44))
        #expect(!NowPlayingCardGeometry.overlaps(more, Self.tallCluster))
        #expect(more.maxY <= Self.laptopBand.minY)
        #expect(geometry.toastTop(height: 60) + 60 <= Self.laptopBand.minY)
    }

    @Test("Laptop with the failure block: the controls scroll inside their own viewport; the media and the band are untouched")
    func laptopFailureScrollsBelowTheBand() throws {
        let normal = try Self.laptopLayout()
        let failed = try Self.laptopLayout(controls: Self.laptopControls + CGFloat(NowPlayingContentMetricsTests.failureBlockHeight))
        #expect(failed.layout.controlsRequireScrolling)
        #expect(failed.layout.controlsViewport == normal.layout.controlsViewport)
        #expect(failed.layout.controlsViewport.lowerBound >= Self.laptopBand.maxY)
        #expect(failed.layout.artworkSize == normal.layout.artworkSize)
        #expect(!failed.layout.mediaRequiresScrolling)
    }

    @Test("Laptop at accessibility sizes: each viewport scrolls on its own and neither crosses the band")
    func laptopAccessibilityOverflowStaysInItsViewport() throws {
        let (layout, _) = try Self.laptopLayout(
            titleBlock: 160,
            controls: 820,
            isAccessibilitySize: true
        )
        #expect(layout.mediaRequiresScrolling)
        #expect(layout.controlsRequireScrolling)
        #expect(layout.mediaViewport.upperBound <= Self.laptopBand.minY)
        #expect(layout.controlsViewport.lowerBound >= Self.laptopBand.maxY)
        #expect(layout.foldGap == Self.laptopBand.height)
    }

    @Test("Laptop before measuring: the artwork takes the room the paddings leave and nothing is reported as scrolling")
    func laptopUnmeasured() throws {
        let (layout, _) = try Self.laptopLayout(titleBlock: nil, controls: nil)
        #expect(layout.mediaSpan == nil)
        #expect(layout.controlsSpan == nil)
        #expect(layout.controlsSpareHeight == nil)
        #expect(!layout.controlsRequireScrolling)
    }

    @Test("Laptop with the pane expanded: the controls scroll to reach it; the artwork does not shrink for it")
    func laptopExpandedPane() throws {
        let viewport = Self.tallWindow.height - Self.laptopBand.maxY - Self.tallInsets.bottom
        let pane = NowPlayingSecondaryPanePresentation.inlineHeight(viewportHeight: viewport) + 12
        let collapsed = try Self.laptopLayout()
        let expanded = try Self.laptopLayout(expandedPane: pane)
        #expect(expanded.layout.controlsRequireScrolling)
        #expect(expanded.layout.artworkSize == collapsed.layout.artworkSize)
        #expect(expanded.layout.controlsSpan == collapsed.layout.controlsSpan)
    }

    @Test("Laptop takes the disclosure row's measured height: a taller row costs the controls' spare room, never the band or the media")
    func laptopMeasuredRowHeight() throws {
        let regular = try Self.laptopLayout()
        let taller = try Self.laptopLayout(controls: Self.laptopControls + 40)
        let regularSpare = try #require(regular.layout.controlsSpareHeight)
        let tallerSpare = try #require(taller.layout.controlsSpareHeight)
        #expect(abs((regularSpare - tallerSpare) - 40) < 0.001)
        #expect(taller.layout.controlsViewport == regular.layout.controlsViewport)
        #expect(taller.layout.mediaSpan == regular.layout.mediaSpan)
    }

    @Test("Open portrait: one window-sized card under the top bar; the stack and the collapsed row fit at L, More clear of the cluster")
    func openPortraitFitsWithTheRow() throws {
        let surface = Self.surface(
            window: Self.tallWindow,
            insets: Self.tallInsets,
            pose: .regularFlat,
            occlusions: [Self.tallCluster]
        )
        let geometry = surface.playerGeometry(allocation: CGRect(origin: .zero, size: Self.tallWindow))
        let rows = CGFloat(NowPlayingContentMetricsTests.rowsAtLarge) + Self.disclosureRow
        let metrics = NowPlayingContentMetrics(
            containerSize: Self.tallWindow,
            cardGeometry: geometry,
            dynamicTypeSize: .large,
            horizontalSizeClass: .regular,
            measurements: NowPlayingContentMeasurements(rowsHeight: rows)
        )
        #expect(geometry.contentInsets == Self.tallInsets)
        #expect(!metrics.requiresScrolling)
        #expect(try #require(metrics.utilityRowMaxY) <= Self.tallWindow.height - Self.tallInsets.bottom)
        let more = CGRect(origin: geometry.moreOrigin, size: CGSize(width: 44, height: 44))
        #expect(!NowPlayingCardGeometry.overlaps(more, Self.tallCluster))
        #expect(more.minY >= Self.tallInsets.top)
    }

    @Test("The disclosure row and the picker are measured as they render: the row a 44 pt control at least, both growing with Dynamic Type")
    func measuredControlHeights() {
        let row = Self.measuredRowHeight()
        let rowAX = Self.measuredRowHeight(.accessibility4)
        #expect(row >= 44)
        #expect(rowAX > row)
        let picker = Self.measuredPickerHeight()
        let pickerAX = Self.measuredPickerHeight(.accessibility4)
        #expect(picker > 0)
        #expect(pickerAX >= picker)
    }

    @Test("Book: the measured picker sits in the pane below its top inset, clear of the band and the status cluster")
    func pickerClearsTheClusterAndTheBand() throws {
        let safe = Self.safeRect(Self.wideWindow, Self.wideInsets)
        let (_, paneAllocation) = try Self.split(band: Self.bookBand)
        let content = Self.surface(pose: .foldedVertical(band: Self.bookBand)).paneGeometry(allocation: paneAllocation).contentFrame
        let picker = CGRect(
            x: content.minX + 16,
            y: content.minY + NowPlayingSecondaryPaneView.pickerTopPadding,
            width: content.width - 32,
            height: Self.measuredPickerHeight()
        )
        #expect(Self.contains(safe, picker))
        #expect(picker.minX >= Self.bookBand.maxX)
        #expect(!NowPlayingCardGeometry.overlaps(picker, Self.wideCluster))

        // A region over the pane's top pushes the measured picker below it.
        let region = CGRect(x: 700, y: 0, width: 84, height: 124)
        let pushed = Self.surface(pose: .foldedVertical(band: Self.bookBand), occlusions: [region])
            .paneGeometry(allocation: paneAllocation).contentFrame
        let pushedPicker = CGRect(
            x: pushed.minX + 16,
            y: pushed.minY + NowPlayingSecondaryPaneView.pickerTopPadding,
            width: pushed.width - 32,
            height: Self.measuredPickerHeight(.accessibility4)
        )
        #expect(!NowPlayingCardGeometry.overlaps(pushedPicker, region))
    }

    @Test("A region over the pane's lower half keeps its content above that region")
    func lowerOcclusionInThePane() {
        let region = CGRect(x: 600, y: 400, width: 40, height: 40)
        let pane = Self.surface(pose: .regularFlat, occlusions: [region])
            .paneGeometry(allocation: CGRect(x: 433.5, y: 0, width: 433.5, height: 635))
        #expect(pane.contentInsets.bottom == CGFloat(635 - 400))
        #expect(!NowPlayingCardGeometry.overlaps(pane.contentFrame, region))
        // Beside the pane's column, a region changes nothing.
        let beside = Self.surface(pose: .regularFlat, occlusions: [CGRect(x: 200, y: 400, width: 40, height: 40)])
            .paneGeometry(allocation: CGRect(x: 433.5, y: 0, width: 433.5, height: 635))
        #expect(beside.contentInsets == EdgeInsets())
    }

    @Test("The expanded row's bounded area: three fifths of its viewport within 280–480 pt")
    func inlinePaneHeight() {
        #expect(NowPlayingSecondaryPanePresentation.inlineHeight(viewportHeight: 835) == 480)
        #expect(NowPlayingSecondaryPanePresentation.inlineHeight(viewportHeight: 421.5) == 280)
        #expect(NowPlayingSecondaryPanePresentation.inlineHeight(viewportHeight: 600) == 360)
    }

    // MARK: Routes and the unchanged card

    @Test("Beside the player the four entry points select the pane; Show Description selects Show Notes")
    func splitRoutes() {
        #expect(NowPlayingSecondaryRoute(destination: .upNext, paneStyle: .beside) == .selectPane(.upNext))
        #expect(NowPlayingSecondaryRoute(destination: .chapters, paneStyle: .beside) == .selectPane(.chapters))
        #expect(NowPlayingSecondaryRoute(destination: .transcript, paneStyle: .beside) == .selectPane(.transcript))
        #expect(NowPlayingSecondaryRoute(destination: .showDescription, paneStyle: .beside) == .selectPane(.showNotes))
    }

    @Test("One card (compact, the iPad, the tall foldable display) keeps today's sheets and the episode page")
    func singleRoutesAreToday() {
        for style in [NowPlayingSecondaryPaneStyle.entryPointsOnly, .disclosure] {
            #expect(NowPlayingSecondaryRoute(destination: .upNext, paneStyle: style) == .presentSheet(.upNext))
            #expect(NowPlayingSecondaryRoute(destination: .chapters, paneStyle: style) == .presentSheet(.chapters))
            #expect(NowPlayingSecondaryRoute(destination: .transcript, paneStyle: style) == .presentSheet(.transcript))
            #expect(NowPlayingSecondaryRoute(destination: .showDescription, paneStyle: style) == .openEpisode)
        }
    }

    @Test("A missing transcript keeps the request flow in every arrangement; a completed one routes")
    func transcriptGeneration() {
        for style in [NowPlayingSecondaryPaneStyle.entryPointsOnly, .disclosure, .beside] {
            #expect(NowPlayingSecondaryRoute.transcriptAction(hasCompletedTranscript: false, paneStyle: style) == .generateTranscript)
        }
        #expect(NowPlayingSecondaryRoute.transcriptAction(hasCompletedTranscript: true, paneStyle: .beside) == .selectPane(.transcript))
        #expect(NowPlayingSecondaryRoute.transcriptAction(hasCompletedTranscript: true, paneStyle: .disclosure) == .presentSheet(.transcript))
        #expect(NowPlayingSecondaryRoute.transcriptAction(hasCompletedTranscript: true, paneStyle: .entryPointsOnly) == .presentSheet(.transcript))
    }

    @Test("The pinned iPhone and the iPad resolve today's card, today's geometry and today's actions")
    func compactAndNonFoldableUnchanged() {
        let iPhone = NowPlayingArrangement(
            pose: WindowPose(horizontalSizeClass: .compact, divisionRegions: []),
            windowSize: NowPlayingCardGeometryTests.iPhoneWindow,
            isFoldableScene: false
        )
        let iPad = NowPlayingArrangement(
            pose: WindowPose(horizontalSizeClass: .regular, divisionRegions: []),
            windowSize: CGSize(width: 1032, height: 1376),
            isFoldableScene: false
        )
        #expect(iPhone == .card)
        #expect(iPad == .card)
        #expect(!iPhone.usesWindowSizedSurface)
        #expect(!iPad.usesWindowSizedSurface)
        #expect(iPhone.paneStyle == .entryPointsOnly)
        let pinned = NowPlayingCardGeometryTests.pinnedIPhone()
        #expect(pinned.cardFrame == CGRect(origin: .zero, size: NowPlayingCardGeometryTests.iPhoneWindow))
        #expect(pinned.moreOrigin == CGPoint(x: 338, y: 62))
        #expect(pinned.contentTopPadding == 150)
        let iPadCard = NowPlayingCardGeometry(
            windowSize: CGSize(width: 1032, height: 1376),
            safeAreaInsets: EdgeInsets(top: 24, leading: 0, bottom: 20, trailing: 0),
            isRegular: true,
            isAccessibilitySize: false,
            pose: .regularFlat,
            occlusions: []
        )
        #expect(iPadCard.cardFrame == CGRect(x: (1032.0 - 660) / 2, y: 1376.0 - 860, width: 660, height: 860))
    }

    @Test("A drag that starts in the pane never starts the card's dismiss drag; one outside it still can")
    func paneDragsNeverDismiss() {
        let pane = CGRect(x: 495.5, y: 0, width: 371.5, height: 635)
        #expect(NowPlayingDragIntent.startsInSecondaryPane(CGPoint(x: 600, y: 300), paneFrames: [pane]))
        #expect(!NowPlayingDragIntent.startsInSecondaryPane(CGPoint(x: 200, y: 300), paneFrames: [pane]))
        #expect(!NowPlayingDragIntent.startsInSecondaryPane(CGPoint(x: 600, y: 300), paneFrames: []))
    }
}
