import CoreGraphics
import SwiftUI
import Testing
@testable import OpenCast

@MainActor
@Suite("Now Playing content metrics: the fit rule")
struct NowPlayingContentMetricsTests {
    /// At L, with the chapter bar.
    static let rowsAtLarge = 373.67
    /// At AX XXL, with the utility circles clamped from 132.3 to 74 pt in two grid rows.
    static let rowsAtAccessibilityXXL = 824.33 - 14 - 22 - 2 * (132.3 - 74)
    /// The failure block with the stack spacing above it.
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

    @Test("Closed at L fits: the artwork gives way and the utility row ends inside the safe bottom (y ≤ 644)")
    func closedFitsAtLarge() throws {
        let metrics = Self.closedMetrics(rowsHeight: Self.rowsAtLarge)
        let expectedArtwork = 678 - 92 - (34 + 22) - Self.rowsAtLarge
        #expect(abs(metrics.artworkUpperBound - 225.6) < 0.001)
        #expect(metrics.artworkUpperBound > expectedArtwork)
        #expect(abs(metrics.artworkSize - expectedArtwork) < 0.001)
        #expect(!metrics.requiresScrolling)
        let utilityRowMaxY = try #require(metrics.utilityRowMaxY)
        #expect(utilityRowMaxY <= 644)
        #expect(metrics.leadingPadding == 24)
        #expect(metrics.trailingPadding == 24)
        #expect(metrics.contentWidth == 418)
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

    @Test("AX XXL in Closed scrolls and never clips: the whole stack is laid out, the artwork at today's bound")
    func accessibilityXXLScrolls() throws {
        let metrics = Self.closedMetrics(dynamicTypeSize: .accessibility4, rowsHeight: Self.rowsAtAccessibilityXXL)
        #expect(metrics.topContentPadding == 14)
        #expect(abs(metrics.artworkUpperBound - (678 - 14 - 22) * 0.26) < 0.001)
        #expect(metrics.artworkSize == metrics.artworkUpperBound)
        #expect(metrics.requiresScrolling)
        let stackHeight = try #require(metrics.stackHeight)
        #expect(abs(stackHeight - (14 + metrics.artworkUpperBound + Self.rowsAtAccessibilityXXL + 56)) < 0.001)
        #expect(try #require(metrics.utilityRowMaxY) == stackHeight - metrics.bottomContentPadding)
    }

    @Test("Pinned iPhone at L: today's artwork, today's utility row, and room for the source pill")
    func pinnedIPhoneKeepsTodaysStack() throws {
        // The iPhone 18 Pro's artwork spans y 150–430.8 and its utility row ends at y 750.
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
        // A panel with the room keeps 14 pt gaps.
        #expect(NowPlayingSoundLabPanel.constrainedRowSpacing(
            panelHeight: 214,
            verticalInset: 9,
            rowCount: 3,
            rowHeight: 44
        ) == 14)
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
}
