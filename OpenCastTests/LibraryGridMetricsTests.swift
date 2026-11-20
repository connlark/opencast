import CoreGraphics
import Testing
@testable import OpenCast

@Suite("Library grid metrics")
struct LibraryGridMetricsTests {
    private struct GridCase {
        let width: Double
        let columns: Int
        let tileWidth: Double
    }

    @Test("Phone portrait widths fit two or three columns")
    func phonePortraitWidths() {
        Self.verify(isCompact: true, isAccessibilitySize: false, [
            GridCase(width: 320, columns: 2, tileWidth: 134),
            GridCase(width: 375, columns: 3, tileWidth: 103),
            GridCase(width: 402, columns: 3, tileWidth: 112),
            GridCase(width: 440, columns: 3, tileWidth: 125)
        ])
    }

    @Test("Accessibility text sizes widen compact tiles")
    func compactAccessibilitySizes() {
        Self.verify(isCompact: true, isAccessibilitySize: true, [
            GridCase(width: 320, columns: 1, tileWidth: 280),
            GridCase(width: 402, columns: 2, tileWidth: 175),
            GridCase(width: 874, columns: 3, tileWidth: 270)
        ])
    }

    @Test("Regular widths add columns without a cap")
    func regularWidths() {
        Self.verify(isCompact: false, isAccessibilitySize: false, [
            GridCase(width: 507, columns: 2, tileWidth: 221),
            GridCase(width: 1032, columns: 5, tileWidth: 184),
            GridCase(width: 1366, columns: 7, tileWidth: 174)
        ])
    }

    @Test("Accessibility text sizes reduce regular columns")
    func regularAccessibilitySizes() {
        Self.verify(isCompact: false, isAccessibilitySize: true, [
            GridCase(width: 507, columns: 1, tileWidth: 459),
            GridCase(width: 1032, columns: 3, tileWidth: 317),
            GridCase(width: 1366, columns: 5, tileWidth: 250)
        ])
    }

    @Test("A container too narrow for one tile still lays out one column")
    func zeroWidthKeepsOneColumn() {
        let metrics = LibraryGridMetrics.resolve(containerWidth: 0, isCompact: true, isAccessibilitySize: false)
        #expect(metrics.columnCount == 1)
        #expect(metrics.tileWidth == 0)
        #expect(metrics.columns.count == 1)
    }

    // MARK: The fold band

    private static let bookBand = 455.5...495.5

    @Test("A centered band splits the columns evenly, none crossing it")
    func centeredBand() {
        let metrics = Self.folded(width: 951, band: Self.bookBand)
        #expect(metrics.columnCount == 4)
        #expect(metrics.foldSplit?.leadingColumnCount == 2)
        #expect(metrics.tileWidth == 195)
        Self.expectClear(metrics, width: 951, band: Self.bookBand)
    }

    @Test("Beside a trailing rail the grid's own width ends at the safe edge, and the trailing side holds what fits")
    func bandBesideRail() {
        let metrics = Self.folded(width: 867, band: Self.bookBand)
        #expect(metrics.columnCount == 3)
        #expect(metrics.foldSplit?.leadingColumnCount == 2)
        #expect(metrics.tileWidth == 195)
        Self.expectClear(metrics, width: 867, band: Self.bookBand)
    }

    @Test("At accessibility sizes Book's safe column holds a column on each side of the band")
    func accessibilityBesideRail() {
        let metrics = Self.folded(width: 867, band: Self.bookBand, isAccessibilitySize: true)
        #expect(metrics.columnCount == 2)
        #expect(metrics.foldSplit?.leadingColumnCount == 1)
        #expect(metrics.tileWidth == 323)
        Self.expectClear(metrics, width: 867, band: Self.bookBand)
    }

    @Test("An off-centre band gives each side its own column count and the tiles the narrower tile")
    func offCentreBand() {
        let band = 300.0...340.0
        let metrics = Self.folded(width: 951, band: band)
        #expect(metrics.columnCount == 4)
        #expect(metrics.foldSplit?.leadingColumnCount == 1)
        #expect(metrics.tileWidth == 177)
        Self.expectClear(metrics, width: 951, band: band)
    }

    @Test("When the sides hold fewer than two columns, one column sits clear on the wider side")
    func narrowContainers() {
        let even = Self.folded(width: 400, band: 180...220)
        #expect(even.columnCount == 1)
        #expect(even.foldSplit?.leadingColumnCount == 1)
        #expect(even.tileWidth == 132)
        Self.expectClear(even, width: 400, band: 180...220)

        let leading = Self.folded(width: 520, band: 300...340)
        #expect(leading.columnCount == 1)
        #expect(leading.foldSplit?.leadingColumnCount == 1)
        #expect(leading.tileWidth == 252)
        Self.expectClear(leading, width: 520, band: 300...340)

        let trailing = Self.folded(width: 520, band: 100...140)
        #expect(trailing.columnCount == 1)
        #expect(trailing.foldSplit?.leadingColumnCount == 0)
        #expect(trailing.foldSplit?.leadingOffset == 140)
        #expect(trailing.tileWidth == 332)
        Self.expectClear(trailing, width: 520, band: 100...140)
    }

    @Test("A band outside the content reserves nothing")
    func bandOutsideContent() {
        let metrics = Self.folded(width: 867, band: 900...940)
        #expect(metrics == LibraryGridMetrics.resolve(containerWidth: 867, isCompact: false, isAccessibilitySize: false))
        #expect(metrics.foldSplit == nil)
    }

    private static func folded(
        width: Double,
        band: ClosedRange<Double>,
        isAccessibilitySize: Bool = false
    ) -> LibraryGridMetrics {
        LibraryGridMetrics.resolve(
            containerWidth: width,
            isCompact: false,
            isAccessibilitySize: isAccessibilitySize,
            reservedBand: band
        )
    }

    /// Each column's horizontal extent in the container's space.
    private static func columnRanges(_ metrics: LibraryGridMetrics) -> [ClosedRange<Double>] {
        guard let split = metrics.foldSplit else {
            return []
        }
        var start = metrics.horizontalMargin + split.leadingOffset
        var ranges: [ClosedRange<Double>] = []
        for item in metrics.columns {
            ranges.append(start...(start + metrics.tileWidth))
            start += metrics.tileWidth + Double(item.spacing ?? 0)
        }
        return ranges
    }

    private static func violations(
        _ metrics: LibraryGridMetrics,
        width: Double,
        band: ClosedRange<Double>
    ) -> [String] {
        guard band.lowerBound < width, band.upperBound > 0 else {
            return metrics.foldSplit == nil ? [] : ["split for a band outside the content"]
        }
        var found: [String] = []
        let ranges = columnRanges(metrics)
        if ranges.count != metrics.columnCount || metrics.columnCount < 1 {
            found.append("\(ranges.count) ranges for \(metrics.columnCount) columns")
        }
        for range in ranges {
            if range.upperBound > band.lowerBound && range.lowerBound < band.upperBound {
                found.append("column \(range) crosses the band")
            }
            if range.lowerBound < metrics.horizontalMargin - 0.001
                || range.upperBound > width - metrics.horizontalMargin + 0.001 {
                found.append("column \(range) outside the content")
            }
        }
        if let gridWidth = metrics.foldedGridWidth, let first = ranges.first, let last = ranges.last,
           abs((last.upperBound - first.lowerBound) - Double(gridWidth)) > 0.001 {
            found.append("grid width \(gridWidth) for columns spanning \(last.upperBound - first.lowerBound)")
        }
        return found
    }

    private static func expectClear(_ metrics: LibraryGridMetrics, width: Double, band: ClosedRange<Double>) {
        let found = violations(metrics, width: width, band: band)
        #expect(found.isEmpty, "\(found)")
    }

    private static func verify(
        isCompact: Bool,
        isAccessibilitySize: Bool,
        _ gridCases: [GridCase]
    ) {
        for gridCase in gridCases {
            let metrics = LibraryGridMetrics.resolve(
                containerWidth: gridCase.width,
                isCompact: isCompact,
                isAccessibilitySize: isAccessibilitySize
            )
            #expect(metrics.columnCount == gridCase.columns, "width \(gridCase.width)")
            #expect(metrics.tileWidth == gridCase.tileWidth, "width \(gridCase.width)")
            #expect(metrics.columns.count == gridCase.columns, "width \(gridCase.width)")
        }
    }
}
