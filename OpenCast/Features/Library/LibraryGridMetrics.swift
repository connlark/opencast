import SwiftUI

nonisolated struct LibraryGridMetrics: Equatable {
    static let compactColumnLimit = 3

    /// In the grid content's space, which starts one horizontal margin in from the container.
    struct FoldSplit: Equatable {
        let leadingColumnCount: Int
        let leadingOffset: Double
        /// From the last leading column to the first trailing one: the band and a margin each side.
        let bandGap: Double
    }

    let columnCount: Int
    let tileWidth: Double
    let columnSpacing: Double
    let rowSpacing: Double
    let horizontalMargin: Double
    let isCompact: Bool
    /// Nil when no band is reserved: the columns are flexible and fill the width.
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

        func fittingColumns(in availableWidth: Double) -> Int {
            let fitting = Int(((availableWidth + columnSpacing) / (minimumTileWidth + columnSpacing)).rounded(.down))
            return min(max(fitting, 0), columnLimit)
        }

        func tileWidth(columns: Int, in availableWidth: Double) -> Double {
            max(((availableWidth - columnSpacing * Double(columns - 1)) / Double(columns)).rounded(.down), 0)
        }
    }

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

    /// A horizontal fold crosses every column of a vertically scrolling grid, so only a vertical
    /// fold reserves a band.
    static func reservedBand(for pose: WindowPose) -> ClosedRange<Double>? {
        switch pose {
        case .foldedVertical(let band):
            band.minX...band.maxX
        case .compact, .regularFlat, .foldedHorizontal:
            nil
        }
    }

    /// `reservedBand` is in the container's space; nil, or a band outside the container, gives the
    /// full-width grid.
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
