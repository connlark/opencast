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
