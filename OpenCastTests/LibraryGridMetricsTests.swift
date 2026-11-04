import CoreGraphics
import Testing
@testable import OpenCast

/// Expected values come from the resolver's formula, not device predictions:
///
///     available = max(width - 2 * margin, 0)
///     columns   = clamp(floor((available + spacing) / (minimum + spacing)), 1, limit)
///     tileWidth = floor((available - spacing * (columns - 1)) / columns)
///
/// Compact: minimum 100 (150 at accessibility sizes), spacing 12, margin 20,
/// limit 3. Regular: minimum 160 (240), spacing 16, margin 24, no limit.
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
            // available 280: floor(292 / 112) = 2; floor(268 / 2) = 134
            GridCase(width: 320, columns: 2, tileWidth: 134),
            // available 335: floor(347 / 112) = 3; floor(311 / 3) = 103
            GridCase(width: 375, columns: 3, tileWidth: 103),
            // available 362: floor(374 / 112) = 3; floor(338 / 3) = 112
            GridCase(width: 402, columns: 3, tileWidth: 112),
            // available 400: floor(412 / 112) = 3; floor(376 / 3) = 125
            GridCase(width: 440, columns: 3, tileWidth: 125)
        ])
    }

    @Test("Wide compact windows stop at three columns")
    func compactLandscapeCapsColumns() {
        Self.verify(isCompact: true, isAccessibilitySize: false, [
            // available 834: floor(846 / 112) = 7, capped to 3; floor(810 / 3) = 270
            GridCase(width: 874, columns: 3, tileWidth: 270),
            // available 916: floor(928 / 112) = 8, capped to 3; floor(892 / 3) = 297
            GridCase(width: 956, columns: 3, tileWidth: 297)
        ])
    }

    @Test("Accessibility text sizes widen compact tiles")
    func compactAccessibilitySizes() {
        Self.verify(isCompact: true, isAccessibilitySize: true, [
            // available 280: floor(292 / 162) = 1; floor(280 / 1) = 280
            GridCase(width: 320, columns: 1, tileWidth: 280),
            // available 362: floor(374 / 162) = 2; floor(350 / 2) = 175
            GridCase(width: 402, columns: 2, tileWidth: 175),
            // available 834: floor(846 / 162) = 5, capped to 3; floor(810 / 3) = 270
            GridCase(width: 874, columns: 3, tileWidth: 270)
        ])
    }

    @Test("Regular widths add columns without a cap")
    func regularWidths() {
        Self.verify(isCompact: false, isAccessibilitySize: false, [
            // available 459: floor(475 / 176) = 2; floor(443 / 2) = 221
            GridCase(width: 507, columns: 2, tileWidth: 221),
            // available 984: floor(1000 / 176) = 5; floor(920 / 5) = 184
            GridCase(width: 1032, columns: 5, tileWidth: 184),
            // available 1318: floor(1334 / 176) = 7; floor(1222 / 7) = 174
            GridCase(width: 1366, columns: 7, tileWidth: 174)
        ])
    }

    @Test("Accessibility text sizes reduce regular columns")
    func regularAccessibilitySizes() {
        Self.verify(isCompact: false, isAccessibilitySize: true, [
            // available 459: floor(475 / 256) = 1; floor(459 / 1) = 459
            GridCase(width: 507, columns: 1, tileWidth: 459),
            // available 984: floor(1000 / 256) = 3; floor(952 / 3) = 317
            GridCase(width: 1032, columns: 3, tileWidth: 317),
            // available 1318: floor(1334 / 256) = 5; floor(1254 / 5) = 250
            GridCase(width: 1366, columns: 5, tileWidth: 250)
        ])
    }

    @Test("Spacing and margins follow the width class")
    func spacingFollowsWidthClass() {
        let compact = LibraryGridMetrics.resolve(containerWidth: 402, isCompact: true, isAccessibilitySize: false)
        let regular = LibraryGridMetrics.resolve(containerWidth: 1032, isCompact: false, isAccessibilitySize: false)

        #expect(compact.isCompact)
        #expect(compact.columnSpacing == 12)
        #expect(compact.rowSpacing == 18)
        #expect(compact.horizontalMargin == 20)
        #expect(!regular.isCompact)
        #expect(regular.columnSpacing == 16)
        #expect(regular.rowSpacing == 24)
        #expect(regular.horizontalMargin == 24)
    }

    @Test("Every width from 0 to 1400 resolves to a grid that fits", arguments: [true, false], [true, false])
    func everyWidthFits(isCompact: Bool, isAccessibilitySize: Bool) {
        let minimumTileWidth: Double = switch (isCompact, isAccessibilitySize) {
        case (true, false): 100
        case (true, true): 150
        case (false, false): 160
        case (false, true): 240
        }
        var violations: [String] = []
        var previousColumnCount = 1
        for width in 0...1400 {
            let metrics = LibraryGridMetrics.resolve(
                containerWidth: Double(width),
                isCompact: isCompact,
                isAccessibilitySize: isAccessibilitySize
            )
            let columnCount = metrics.columnCount
            let availableWidth = max(Double(width) - metrics.horizontalMargin * 2, 0)
            let usedWidth = Double(columnCount) * metrics.tileWidth
                + Double(columnCount - 1) * metrics.columnSpacing
            let isAtLimit = isCompact && columnCount == LibraryGridMetrics.compactColumnLimit
            let widthForAnotherColumn = Double(columnCount + 1) * minimumTileWidth
                + Double(columnCount) * metrics.columnSpacing

            if columnCount < 1 {
                violations.append("\(width): \(columnCount) columns")
            }
            if isCompact && columnCount > LibraryGridMetrics.compactColumnLimit {
                violations.append("\(width): \(columnCount) compact columns")
            }
            if metrics.tileWidth < 0 {
                violations.append("\(width): negative tile width \(metrics.tileWidth)")
            }
            if usedWidth > availableWidth + 0.001 {
                violations.append("\(width): uses \(usedWidth) of \(availableWidth)")
            }
            if columnCount > 1 && metrics.tileWidth < minimumTileWidth {
                violations.append("\(width): tile \(metrics.tileWidth) below minimum \(minimumTileWidth)")
            }
            if !isAtLimit && widthForAnotherColumn <= availableWidth {
                violations.append("\(width): room for another column at \(columnCount)")
            }
            if columnCount < previousColumnCount {
                violations.append("\(width): columns fell from \(previousColumnCount) to \(columnCount)")
            }
            if metrics.columns.count != columnCount {
                violations.append("\(width): \(metrics.columns.count) grid items for \(columnCount) columns")
            }
            previousColumnCount = columnCount
        }

        #expect(violations.isEmpty, "\(violations.prefix(20))")
    }

    // MARK: The fold band

    /// The 951-pt landscape window and its 40-pt band at 455.5 are fixtures
    /// shaped like the probe's Book reading (A2), not values the code knows.
    private static let bookBand = 455.5...495.5

    @Test("A centered band splits the columns evenly, none crossing it")
    func centeredBand() {
        // Each side 455.5: available 407.5, floor(423.5 / 176) = 2, floor(391.5 / 2) = 195.
        let metrics = Self.folded(width: 951, band: Self.bookBand)
        #expect(metrics.columnCount == 4)
        #expect(metrics.foldSplit?.leadingColumnCount == 2)
        #expect(metrics.tileWidth == 195)
        Self.expectClear(metrics, width: 951, band: Self.bookBand)
    }

    @Test("Beside a trailing rail the grid's own width ends at the safe edge, and the trailing side holds what fits")
    func bandBesideRail() {
        // Book's safe column is 867 pt wide (the rail's 84 pt lies outside the grid's proxy).
        // Trailing side 867 - 495.5 = 371.5: available 323.5, one column; tiles keep 195.
        let metrics = Self.folded(width: 867, band: Self.bookBand)
        #expect(metrics.columnCount == 3)
        #expect(metrics.foldSplit?.leadingColumnCount == 2)
        #expect(metrics.tileWidth == 195)
        Self.expectClear(metrics, width: 867, band: Self.bookBand)
    }

    @Test("At accessibility sizes Book's safe column holds a column on each side of the band")
    func accessibilityBesideRail() {
        // Leading 407.5 and trailing 323.5 available each hold one 240 pt column; tiles take 323.
        let metrics = Self.folded(width: 867, band: Self.bookBand, isAccessibilitySize: true)
        #expect(metrics.columnCount == 2)
        #expect(metrics.foldSplit?.leadingColumnCount == 1)
        #expect(metrics.tileWidth == 323)
        Self.expectClear(metrics, width: 867, band: Self.bookBand)
    }

    @Test("Beside a leading rail the band arrives shifted into the grid's space")
    func bandBesideLeadingRail() {
        // The same 951 pt display with the rail leading: the grid starts at the rail's edge, so the
        // band sits at 371.5 in its space. Leading 371.5 holds one column, trailing 455.5 two.
        let band = 371.5...411.5
        let metrics = Self.folded(width: 867, band: band)
        #expect(metrics.columnCount == 3)
        #expect(metrics.foldSplit?.leadingColumnCount == 1)
        #expect(metrics.tileWidth == 195)
        Self.expectClear(metrics, width: 867, band: band)
    }

    @Test("An off-centre band gives each side its own column count and the tiles the narrower tile")
    func offCentreBand() {
        // Leading 300: available 252, one column of 252. Trailing 611: available 563,
        // floor(579 / 176) = 3, floor(531 / 3) = 177. Tiles take 177.
        let band = 300.0...340.0
        let metrics = Self.folded(width: 951, band: band)
        #expect(metrics.columnCount == 4)
        #expect(metrics.foldSplit?.leadingColumnCount == 1)
        #expect(metrics.tileWidth == 177)
        Self.expectClear(metrics, width: 951, band: band)
    }

    @Test("A wider band is reserved in full")
    func widerBand() {
        // Leading 400: available 352, 2 columns of 168. Trailing 391: available 343, 2 of 163.
        let band = 400.0...560.0
        let metrics = Self.folded(width: 951, band: band)
        #expect(metrics.columnCount == 4)
        #expect(metrics.tileWidth == 163)
        Self.expectClear(metrics, width: 951, band: band)
    }

    @Test("When the sides hold fewer than two columns, one column sits clear on the wider side")
    func narrowContainers() {
        // Equal sides of 180 hold none (available 132 < 160): one column on the leading side.
        let even = Self.folded(width: 400, band: 180...220)
        #expect(even.columnCount == 1)
        #expect(even.foldSplit?.leadingColumnCount == 1)
        #expect(even.tileWidth == 132)
        Self.expectClear(even, width: 400, band: 180...220)

        // Leading 300 holds one, trailing 180 none: still one column, on the wider leading side.
        let leading = Self.folded(width: 520, band: 300...340)
        #expect(leading.columnCount == 1)
        #expect(leading.foldSplit?.leadingColumnCount == 1)
        #expect(leading.tileWidth == 252)
        Self.expectClear(leading, width: 520, band: 300...340)

        // Trailing 380 is wider: the column starts one margin past the band.
        let trailing = Self.folded(width: 520, band: 100...140)
        #expect(trailing.columnCount == 1)
        #expect(trailing.foldSplit?.leadingColumnCount == 0)
        #expect(trailing.foldSplit?.leadingOffset == 140)
        #expect(trailing.tileWidth == 332)
        Self.expectClear(trailing, width: 520, band: 100...140)
    }

    @Test("Accessibility sizes keep the larger minimum on each side")
    func accessibilitySizesInFold() {
        // Each side's 407.5 holds floor(423.5 / 256) = 1 column of 407.
        let metrics = Self.folded(width: 951, band: Self.bookBand, isAccessibilitySize: true)
        #expect(metrics.columnCount == 2)
        #expect(metrics.tileWidth == 407)
        Self.expectClear(metrics, width: 951, band: Self.bookBand)
    }

    @Test("A band outside the content reserves nothing")
    func bandOutsideContent() {
        let metrics = Self.folded(width: 867, band: 900...940)
        #expect(metrics == LibraryGridMetrics.resolve(containerWidth: 867, isCompact: false, isAccessibilitySize: false))
        #expect(metrics.foldSplit == nil)
    }

    @Test("Only a vertical fold reserves a band; no region, an inactive one, and a horizontal fold keep the full width")
    func poseDecidesTheBand() {
        let vertical = CGRect(x: 455.5, y: 0, width: 40, height: 669)
        let horizontal = CGRect(x: 0, y: 455.5, width: 669, height: 40)
        let book = WindowPose(horizontalSizeClass: .regular, divisionRegions: [WindowDivisionRegion(frame: vertical, isActive: true)])
        let flat = WindowPose(horizontalSizeClass: .regular, divisionRegions: [WindowDivisionRegion(frame: vertical, isActive: false)])
        let laptop = WindowPose(horizontalSizeClass: .regular, divisionRegions: [WindowDivisionRegion(frame: horizontal, isActive: true)])
        let noRegion = WindowPose(horizontalSizeClass: .regular, divisionRegions: [])
        let closed = WindowPose(horizontalSizeClass: .compact, divisionRegions: [WindowDivisionRegion(frame: vertical, isActive: true)])

        #expect(LibraryGridMetrics.reservedBand(for: book) == 455.5...495.5)
        for pose in [flat, laptop, noRegion, closed] {
            #expect(LibraryGridMetrics.reservedBand(for: pose) == nil, "\(pose)")
        }
        let unfolded = LibraryGridMetrics.resolve(containerWidth: 951, isCompact: false, isAccessibilitySize: false)
        let laptopMetrics = LibraryGridMetrics.resolve(
            containerWidth: 951,
            isCompact: false,
            isAccessibilitySize: false,
            reservedBand: LibraryGridMetrics.reservedBand(for: laptop)
        )
        #expect(laptopMetrics == unfolded)
        #expect(unfolded.foldSplit == nil)
    }

    @Test("Across widths and band positions no column crosses the band or leaves the content", arguments: [false, true])
    func everyBandStaysClear(isAccessibilitySize: Bool) {
        var violations: [String] = []
        for width in stride(from: 300.0, through: 1400, by: 25) {
            for bandStart in stride(from: 0.0, through: width, by: 25) {
                let band = bandStart...(bandStart + 40)
                let metrics = Self.folded(width: width, band: band, isAccessibilitySize: isAccessibilitySize)
                violations += Self.violations(metrics, width: width, band: band)
                    .map { "\(width) band \(bandStart): \($0)" }
            }
        }
        #expect(violations.isEmpty, "\(violations.prefix(20))")
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
