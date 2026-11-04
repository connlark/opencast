import SwiftUI

/// Column layout for the Library grid, resolved from the measured container
/// width rather than a device class: Split View, Stage Manager, and rotation
/// all change the width, not the idiom. Compact (phone-like) grids stop at
/// three columns so artwork stays large; accessibility text sizes raise the
/// minimum tile width so titles keep room, down to a single column.
///
/// A vertical fold (`WindowPose.foldedVertical`) crossing the grid is
/// reserved in full: no tile intersects the band. Each side of the band
/// takes the same width rule (its own margins, minimum tile and column
/// limit) and holds as many whole columns as fit; the tiles share the
/// narrower side's tile width so every tile matches. When the two sides
/// cannot hold two columns between them, one column sits clear of the band
/// on the wider side.
nonisolated struct LibraryGridMetrics: Equatable {
    static let compactColumnLimit = 3

    /// The columns around a reserved band, in the grid content's leading
    /// space: the content starts one horizontal margin in from the
    /// container's leading edge.
    struct FoldSplit: Equatable {
        /// Columns on the leading side of the band; the rest follow it.
        let leadingColumnCount: Int
        /// The first column's offset from the content's leading edge.
        let leadingOffset: Double
        /// From the last leading column to the first trailing one: the
        /// band and the margin on each side of it.
        let bandGap: Double
    }

    let columnCount: Int
    let tileWidth: Double
    let columnSpacing: Double
    let rowSpacing: Double
    let horizontalMargin: Double
    let isCompact: Bool
    /// Nil when no band is reserved: the columns fill the width as flexible
    /// items.
    var foldSplit: FoldSplit?

    private struct WidthRule {
        let minimumTileWidth: Double
        let columnSpacing: Double
        let rowSpacing: Double
        let horizontalMargin: Double
        let columnLimit: Int

        init(isCompact: Bool, isAccessibilitySize: Bool) {
            if isCompact {
                minimumTileWidth = isAccessibilitySize ? 150 : 100
                columnSpacing = 12
                rowSpacing = 18
                horizontalMargin = 20
                columnLimit = LibraryGridMetrics.compactColumnLimit
            } else {
                minimumTileWidth = isAccessibilitySize ? 240 : 160
                columnSpacing = 16
                rowSpacing = 24
                horizontalMargin = 24
                columnLimit = .max
            }
        }

        func availableWidth(in width: Double) -> Double {
            max(width - horizontalMargin * 2, 0)
        }

        /// Whole columns of at least the minimum tile width, up to the
        /// limit; zero when not even one fits.
        func fittingColumns(in availableWidth: Double) -> Int {
            let fitting = Int(((availableWidth + columnSpacing) / (minimumTileWidth + columnSpacing)).rounded(.down))
            return min(max(fitting, 0), columnLimit)
        }

        func tileWidth(columns: Int, in availableWidth: Double) -> Double {
            max(((availableWidth - columnSpacing * Double(columns - 1)) / Double(columns)).rounded(.down), 0)
        }
    }

    /// The grids' row spacing for a width class, which is also the shell's
    /// row gap above the tab accessory for screens whose rows abut.
    static func rowSpacing(isCompact: Bool) -> Double {
        WidthRule(isCompact: isCompact, isAccessibilitySize: false).rowSpacing
    }

    static func resolve(
        containerWidth: Double,
        isCompact: Bool,
        isAccessibilitySize: Bool
    ) -> Self {
        let rule = WidthRule(isCompact: isCompact, isAccessibilitySize: isAccessibilitySize)
        let availableWidth = rule.availableWidth(in: containerWidth)
        let columnCount = max(rule.fittingColumns(in: availableWidth), 1)
        return Self(
            columnCount: columnCount,
            tileWidth: rule.tileWidth(columns: columnCount, in: availableWidth),
            columnSpacing: rule.columnSpacing,
            rowSpacing: rule.rowSpacing,
            horizontalMargin: rule.horizontalMargin,
            isCompact: isCompact
        )
    }

    /// The horizontal extent a grid reserves for a pose: a vertical fold's
    /// band (Book), in the space its regions were read in. A horizontal fold
    /// (Laptop) crosses every column of a vertically scrolling grid, so it
    /// reserves nothing, as no fold does.
    static func reservedBand(for pose: WindowPose) -> ClosedRange<Double>? {
        switch pose {
        case .foldedVertical(let band):
            band.minX...band.maxX
        case .compact, .regularFlat, .foldedHorizontal:
            nil
        }
    }

    /// - Parameter reservedBand: the fold band's leading and trailing edges
    ///   in the container's space; nil, or a band outside the container,
    ///   gives the full-width grid.
    static func resolve(
        containerWidth: Double,
        isCompact: Bool,
        isAccessibilitySize: Bool,
        reservedBand: ClosedRange<Double>?
    ) -> Self {
        let contentStart = 0.0
        let contentEnd = containerWidth
        guard let reservedBand, reservedBand.lowerBound < contentEnd, reservedBand.upperBound > contentStart else {
            return resolve(containerWidth: containerWidth, isCompact: isCompact, isAccessibilitySize: isAccessibilitySize)
        }

        let rule = WidthRule(isCompact: isCompact, isAccessibilitySize: isAccessibilitySize)
        let leadingAvailable = rule.availableWidth(in: max(reservedBand.lowerBound - contentStart, 0))
        let trailingAvailable = rule.availableWidth(in: max(contentEnd - reservedBand.upperBound, 0))
        var leadingColumns = rule.fittingColumns(in: leadingAvailable)
        var trailingColumns = rule.fittingColumns(in: trailingAvailable)
        let tileWidth: Double
        if leadingColumns + trailingColumns >= 2 {
            let sideTileWidths = [(leadingColumns, leadingAvailable), (trailingColumns, trailingAvailable)]
                .filter { columns, _ in columns > 0 }
                .map { columns, available in rule.tileWidth(columns: columns, in: available) }
            tileWidth = sideTileWidths.min() ?? 0
        } else if leadingAvailable >= trailingAvailable {
            leadingColumns = 1
            trailingColumns = 0
            tileWidth = leadingAvailable.rounded(.down)
        } else {
            leadingColumns = 0
            trailingColumns = 1
            tileWidth = trailingAvailable.rounded(.down)
        }

        // In the content's space the leading side's columns start at 0 and
        // the trailing side's one margin past the band.
        let trailingStart = reservedBand.upperBound - contentStart
        let leadingGroupWidth = Double(leadingColumns) * tileWidth
            + Double(max(leadingColumns - 1, 0)) * rule.columnSpacing
        return Self(
            columnCount: leadingColumns + trailingColumns,
            tileWidth: tileWidth,
            columnSpacing: rule.columnSpacing,
            rowSpacing: rule.rowSpacing,
            horizontalMargin: rule.horizontalMargin,
            isCompact: isCompact,
            foldSplit: FoldSplit(
                leadingColumnCount: leadingColumns,
                leadingOffset: leadingColumns > 0 ? 0 : trailingStart,
                bandGap: trailingStart - leadingGroupWidth
            )
        )
    }

    var columns: [GridItem] {
        guard let foldSplit else {
            return Array(
                repeating: GridItem(.flexible(), spacing: columnSpacing, alignment: .top),
                count: columnCount
            )
        }
        return (0..<columnCount).map { index in
            GridItem(.fixed(tileWidth), spacing: spacing(after: index, in: foldSplit), alignment: .top)
        }
    }

    /// The fixed width of a split grid, its columns and the gaps between
    /// them; nil for a full-width grid. `CGFloat` because a frame takes an
    /// optional width.
    var foldedGridWidth: CGFloat? {
        guard let foldSplit else {
            return nil
        }
        return (0..<max(columnCount - 1, 0)).reduce(Double(columnCount) * tileWidth) { width, index in
            width + spacing(after: index, in: foldSplit)
        }
    }

    private func spacing(after index: Int, in foldSplit: FoldSplit) -> Double {
        index == foldSplit.leadingColumnCount - 1 ? foldSplit.bandGap : columnSpacing
    }
}
