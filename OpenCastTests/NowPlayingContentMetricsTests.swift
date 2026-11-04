import CoreGraphics
import SwiftUI
import Testing
@testable import OpenCast

/// The row heights are OBSERVED: the seeded episode's stack measured on the
/// iPhone Duo simulator's outer display with More top-leading and the artwork
/// fitted. That measurement was the padded stack minus the artwork, so the rows
/// below subtract its paddings (92 / 22 at L, 14 / 22 at AX XXL).
@MainActor
@Suite("Now Playing content metrics: the fit rule")
struct NowPlayingContentMetricsTests {
    /// L with the chapter bar: 487.67 − 92 − 22.
    static let rowsAtLarge = 373.67
    /// L before the chapters load: 431.67 − 92 − 22.
    static let rowsAtLargeWithoutChapters = 317.67
    /// AX XXL: 824.33 − 14 − 22 with the unclamped 132.3 pt utility circles in two
    /// grid rows; the clamp makes them 74 pt, 2 × 58.3 pt shorter.
    static let rowsAtAccessibilityXXL = 824.33 - 14 - 22 - 2 * (132.3 - 74)
    /// The failure block: its label, a two-line message, the Retry button,
    /// its padding and the stack spacing above it.
    static let failureBlockHeight = 136.0
    static let titleBlockAtLarge = 70.0
    static let progressSectionAtLarge = 110.0

    static let closedContainer = CGSize(width: 466, height: 678)

    static func closedMetrics(
        dynamicTypeSize: DynamicTypeSize = .large,
        rowsHeight: CGFloat?,
        titleBlockHeight: CGFloat? = nil,
        progressSectionHeight: CGFloat? = nil,
        occlusions: [CGRect] = NowPlayingCardGeometryTests.closedOcclusions
    ) -> NowPlayingContentMetrics {
        NowPlayingContentMetrics(
            containerSize: closedContainer,
            cardGeometry: NowPlayingCardGeometryTests.closed(
                isAccessibilitySize: dynamicTypeSize.isAccessibilitySize,
                occlusions: occlusions
            ),
            dynamicTypeSize: dynamicTypeSize,
            horizontalSizeClass: .compact,
            measurements: NowPlayingContentMeasurements(
                rowsHeight: rowsHeight,
                titleBlockHeight: titleBlockHeight,
                progressSectionHeight: progressSectionHeight
            )
        )
    }

    @Test("Before the rows are measured the artwork keeps today's bounds")
    func unmeasuredKeepsTodaysBounds() {
        let metrics = Self.closedMetrics(rowsHeight: nil)
        #expect(metrics.artworkSize == metrics.artworkUpperBound)
        #expect(metrics.stackHeight == nil)
        #expect(!metrics.requiresScrolling)
    }

    @Test("Closed at L fits: the artwork gives way and the utility row ends inside the safe bottom (y ≤ 644)")
    func closedFitsAtLarge() throws {
        let metrics = Self.closedMetrics(rowsHeight: Self.rowsAtLarge)
        let expectedArtwork = 678 - 92 - (34 + 22) - Self.rowsAtLarge
        #expect(metrics.artworkUpperBound > expectedArtwork)
        #expect(abs(metrics.artworkSize - expectedArtwork) < 0.001)
        #expect(!metrics.requiresScrolling)
        let utilityRowMaxY = try #require(metrics.utilityRowMaxY)
        #expect(utilityRowMaxY <= 644)
        #expect(metrics.leadingPadding == 24)
        #expect(metrics.trailingPadding == 24)
        #expect(metrics.contentWidth == 418)
    }

    @Test("Room to spare keeps today's upper bound")
    func roomToSpareKeepsTheUpperBound() {
        let metrics = Self.closedMetrics(rowsHeight: 200)
        #expect(metrics.artworkSize == metrics.artworkUpperBound)
        #expect(!metrics.requiresScrolling)
    }

    @Test("A failure block takes its height from the artwork, which still fits above the safe bottom")
    func failureShownStillFits() throws {
        let normal = Self.closedMetrics(rowsHeight: Self.rowsAtLargeWithoutChapters)
        let failed = Self.closedMetrics(rowsHeight: Self.rowsAtLargeWithoutChapters + Self.failureBlockHeight)
        let room = 678 - 92 - (34 + 22) - (Self.rowsAtLargeWithoutChapters + Self.failureBlockHeight)
        #expect(room >= NowPlayingContentMetrics.minimumArtworkSize)
        #expect(abs(failed.artworkSize - room) < 0.001)
        #expect(failed.artworkSize < normal.artworkSize)
        #expect(!failed.requiresScrolling)
        #expect(try #require(failed.utilityRowMaxY) <= 644)
    }

    @Test("At exactly the 64 pt floor the stack still fits")
    func floorStillFits() {
        let rows = 678 - 92 - 56 - NowPlayingContentMetrics.minimumArtworkSize
        let metrics = Self.closedMetrics(rowsHeight: rows)
        #expect(metrics.artworkSize == NowPlayingContentMetrics.minimumArtworkSize)
        #expect(!metrics.requiresScrolling)
    }

    @Test("When the floor and the rows exceed the card the artwork stops at 64 pt and the content scrolls")
    func overflowFloorsAndScrolls() throws {
        let metrics = Self.closedMetrics(rowsHeight: Self.rowsAtLarge + Self.failureBlockHeight)
        #expect(metrics.artworkSize == NowPlayingContentMetrics.minimumArtworkSize)
        #expect(metrics.requiresScrolling)
        let stackHeight = try #require(metrics.stackHeight)
        #expect(abs(stackHeight - (92 + 64 + Self.rowsAtLarge + Self.failureBlockHeight + 56)) < 0.001)
    }

    @Test("At accessibility sizes the artwork keeps today's bound even where shrinking would fit")
    func accessibilityKeepsTheBound() {
        let metrics = Self.closedMetrics(dynamicTypeSize: .accessibility1, rowsHeight: 300)
        #expect(metrics.artworkSize == metrics.artworkUpperBound)
    }

    @Test("AX XXL in Closed scrolls and never clips: the whole stack is laid out, the artwork at today's bound")
    func accessibilityXXLScrolls() throws {
        let metrics = Self.closedMetrics(dynamicTypeSize: .accessibility4, rowsHeight: Self.rowsAtAccessibilityXXL)
        #expect(metrics.topContentPadding == 14)
        // Today's accessibility bound in Closed: (678 − 14 − 22) × 0.26.
        #expect(abs(metrics.artworkUpperBound - (678 - 14 - 22) * 0.26) < 0.001)
        #expect(metrics.artworkSize == metrics.artworkUpperBound)
        #expect(metrics.requiresScrolling)
        let stackHeight = try #require(metrics.stackHeight)
        #expect(abs(stackHeight - (14 + metrics.artworkUpperBound + Self.rowsAtAccessibilityXXL + 56)) < 0.001)
        #expect(try #require(metrics.utilityRowMaxY) == stackHeight - metrics.bottomContentPadding)
    }

    @Test("Pinned iPhone at L: today's artwork, today's utility row, and room for the source pill")
    func pinnedIPhoneKeepsTodaysStack() throws {
        // OBSERVED on the iPhone 18 Pro before this layout (the
        // now_playing_expanded_light screenshot): the artwork spans y 150–430.8
        // and the utility row ends at y 750, so the rows are 750 − 150 − 280.8.
        let rows = 750 - 150 - 280.8
        let geometry = NowPlayingCardGeometry(
            windowSize: NowPlayingCardGeometryTests.iPhoneWindow,
            safeAreaInsets: NowPlayingCardGeometryTests.iPhoneInsets,
            isRegular: false,
            isAccessibilitySize: false,
            pose: .compact,
            occlusions: []
        )
        let metrics = NowPlayingContentMetrics(
            containerSize: NowPlayingCardGeometryTests.iPhoneWindow,
            cardGeometry: geometry,
            dynamicTypeSize: .large,
            horizontalSizeClass: .compact,
            measurements: NowPlayingContentMeasurements(rowsHeight: rows)
        )
        #expect(abs(metrics.artworkUpperBound - (874 - 150 - 22) * 0.40) < 0.001)
        #expect(metrics.artworkSize == metrics.artworkUpperBound)
        #expect(abs(try #require(metrics.utilityRowMaxY) - 750) < 0.001)
        let stackHeight = try #require(metrics.stackHeight)
        let spare = 874 - stackHeight
        #expect(spare >= NowPlayingSourcePill.minimumSpareHeight)
    }

    @Test("Pinned iPhone at AX XXXL keeps today's 214.24 pt bound: the safe top moves the content, not the bound")
    func pinnedIPhoneAccessibilityBoundUnchanged() {
        let geometry = NowPlayingCardGeometryTests.pinnedIPhone(isAccessibilitySize: true)
        let metrics = NowPlayingContentMetrics(
            containerSize: NowPlayingCardGeometryTests.iPhoneWindow,
            cardGeometry: geometry,
            dynamicTypeSize: .accessibility5,
            horizontalSizeClass: .compact,
            measurements: NowPlayingContentMeasurements(rowsHeight: 900)
        )
        #expect(abs(metrics.artworkUpperBound - (874 - 28 - 22) * 0.26) < 0.001)
        #expect(metrics.artworkSize == metrics.artworkUpperBound)
        #expect(metrics.topContentPadding == CGFloat(62 + 28))
    }

    @Test("Pinned iPhone with a failure block: the artwork gives way so the utility row stays inside the safe bottom")
    func pinnedIPhoneFailureFits() throws {
        let rows = 750 - 150 - 280.8 + Self.failureBlockHeight
        let geometry = NowPlayingCardGeometry(
            windowSize: NowPlayingCardGeometryTests.iPhoneWindow,
            safeAreaInsets: NowPlayingCardGeometryTests.iPhoneInsets,
            isRegular: false,
            isAccessibilitySize: false,
            pose: .compact,
            occlusions: []
        )
        let metrics = NowPlayingContentMetrics(
            containerSize: NowPlayingCardGeometryTests.iPhoneWindow,
            cardGeometry: geometry,
            dynamicTypeSize: .large,
            horizontalSizeClass: .compact,
            measurements: NowPlayingContentMeasurements(rowsHeight: rows)
        )
        #expect(metrics.artworkSize < metrics.artworkUpperBound)
        #expect(!metrics.requiresScrolling)
        #expect(try #require(metrics.utilityRowMaxY) <= 874 - 34)
    }

    @Test("Closed at L: the fitted artwork still holds the Sound Lab's three 44 pt rows")
    func closedSoundLabRowsFitTheFittedArtwork() {
        let artwork = Self.closedMetrics(rowsHeight: Self.rowsAtLarge).artworkSize
        let inset = NowPlayingSoundLabLayout(panelWidth: artwork).contentInset
        let spacing = NowPlayingSoundLabPanel.constrainedRowSpacing(
            panelHeight: artwork,
            verticalInset: inset,
            rowCount: 3,
            rowHeight: 44
        )
        #expect(spacing >= 2)
        #expect(2 * inset + 3 * 44 + 2 * spacing <= artwork + 0.001)
        // A panel with the room keeps today's 14 pt gaps.
        #expect(NowPlayingSoundLabPanel.constrainedRowSpacing(
            panelHeight: 214,
            verticalInset: 9,
            rowCount: 3,
            rowHeight: 44
        ) == 14)
    }

    @Test("Today's upper bound never grows past the content width")
    func upperBoundRespectsTheWidth() {
        let metrics = Self.closedMetrics(rowsHeight: 0)
        #expect(metrics.artworkSize <= metrics.contentWidth)
    }

    @Test("Closed: the progress section starts below the status cluster with no spacer at L")
    func closedProgressClearsTheClusterAtLarge() throws {
        let metrics = Self.closedMetrics(
            rowsHeight: Self.rowsAtLarge,
            titleBlockHeight: Self.titleBlockAtLarge,
            progressSectionHeight: Self.progressSectionAtLarge
        )
        #expect(metrics.progressSectionTopSpacer == 0)
        #expect(try #require(metrics.progressSectionSpan).lowerBound >= 174)
    }

    @Test("An occlusion region reaching further down pushes the progress section below it")
    func occlusionPushesTheProgressSectionDown() throws {
        let tallRegion = CGRect(x: 300, y: 0, width: 166, height: 400)
        let metrics = Self.closedMetrics(
            rowsHeight: Self.rowsAtLarge,
            titleBlockHeight: Self.titleBlockAtLarge,
            progressSectionHeight: Self.progressSectionAtLarge,
            occlusions: [tallRegion]
        )
        let progress = try #require(metrics.progressSectionSpan)
        #expect(metrics.progressSectionTopSpacer > 0)
        #expect(abs(progress.lowerBound - 400) < 0.001)
        let stackHeight = try #require(metrics.stackHeight)
        #expect(metrics.requiresScrolling == (stackHeight > 678 + 0.5))
    }

    // MARK: Laptop

    static let laptopWindow = CGSize(width: 669, height: 951)

    static func laptopMetrics(band: CGRect) -> NowPlayingContentMetrics {
        let geometry = NowPlayingCardGeometry(
            windowSize: laptopWindow,
            safeAreaInsets: EdgeInsets(),
            isRegular: true,
            isAccessibilitySize: false,
            pose: .foldedHorizontal(band: band),
            occlusions: []
        )
        return NowPlayingContentMetrics(
            containerSize: geometry.cardFrame.size,
            cardGeometry: geometry,
            dynamicTypeSize: .large,
            horizontalSizeClass: .regular,
            measurements: NowPlayingContentMeasurements(
                rowsHeight: 380,
                titleBlockHeight: Self.titleBlockAtLarge,
                progressSectionHeight: Self.progressSectionAtLarge
            )
        )
    }

    @Test(
        "Laptop keeps the whole title block and progress section off the band",
        arguments: [440.0, 520.0, 600.0, 660.0, 740.0]
    )
    func laptopKeepsTitleAndProgressOffTheBand(bandY: Double) throws {
        let band = CGRect(x: 0, y: bandY, width: 669, height: 40)
        let metrics = Self.laptopMetrics(band: band)
        // The card's top is at window y 91.
        let cardBand = CGFloat(bandY - 91)...CGFloat(bandY - 91 + 40)
        let title = try #require(metrics.titleBlockSpan)
        let progress = try #require(metrics.progressSectionSpan)
        #expect(!NowPlayingCardGeometry.overlaps(title, cardBand))
        #expect(!NowPlayingCardGeometry.overlaps(progress, cardBand))
    }

    @Test("A band clear of the title block and the progress section adds no spacer")
    func laptopBandClearOfTheBlockAddsNothing() {
        let metrics = Self.laptopMetrics(band: CGRect(x: 0, y: 860, width: 669, height: 40))
        #expect(metrics.titleBlockTopSpacer == 0)
    }

    @Test("The finished card's title keeps off Laptop's band the same way")
    func finishedTitleKeepsOffTheBand() {
        let metrics = Self.laptopMetrics(band: CGRect(x: 0, y: 520, width: 669, height: 40))
        let titleTop = metrics.topContentPadding + metrics.artworkUpperBound + metrics.contentSpacing
        let height = CGFloat(Self.titleBlockAtLarge)
        let spacer = metrics.finishedTitleBlockTopSpacer(titleBlockHeight: height)
        let title: ClosedRange<CGFloat> = (titleTop + spacer)...(titleTop + spacer + height)
        #expect(!NowPlayingCardGeometry.overlaps(title, (520 - 91)...(560 - 91)))
        #expect(metrics.finishedTitleBlockTopSpacer(titleBlockHeight: nil) == 0)
    }

    @Test("Laptop with the reported band and the portrait-shaped insets: the title block and the progress section are off the band")
    func laptopReportedBandKeepsTitleAndProgressOff() throws {
        let geometry = NowPlayingCardGeometry(
            windowSize: NowPlayingCardGeometryTests.innerPortraitWindow,
            safeAreaInsets: NowPlayingCardGeometryTests.innerPortraitInsets,
            isRegular: true,
            isAccessibilitySize: false,
            pose: WindowPose(
                horizontalSizeClass: .regular,
                divisionRegions: [WindowDivisionRegion(frame: NowPlayingCardGeometryTests.laptopBand, isActive: true)]
            ),
            occlusions: [NowPlayingCardGeometryTests.innerPortraitCluster]
        )
        let metrics = NowPlayingContentMetrics(
            containerSize: geometry.cardFrame.size,
            cardGeometry: geometry,
            dynamicTypeSize: .large,
            horizontalSizeClass: .regular,
            measurements: NowPlayingContentMeasurements(
                rowsHeight: 380,
                titleBlockHeight: Self.titleBlockAtLarge,
                progressSectionHeight: Self.progressSectionAtLarge
            )
        )
        let band = try #require(geometry.horizontalFold)
        let title = try #require(metrics.titleBlockSpan)
        let progress = try #require(metrics.progressSectionSpan)
        #expect(!NowPlayingCardGeometry.overlaps(title, band))
        #expect(!NowPlayingCardGeometry.overlaps(progress, band))
        #expect(!metrics.requiresScrolling)
    }

    @Test("A band across the title block moves it and the progress section below the band")
    func laptopBandAcrossTheTitleMovesTheBlock() throws {
        let metrics = Self.laptopMetrics(band: CGRect(x: 0, y: 600, width: 669, height: 40))
        #expect(metrics.titleBlockTopSpacer > 0)
        let title = try #require(metrics.titleBlockSpan)
        #expect(title.lowerBound >= 640 - 91 + NowPlayingCardGeometry.foldClearance - 0.001)
    }
}
