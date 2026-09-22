import SwiftUI

/// Column layout for the Library grid, resolved from the measured container
/// width rather than a device class: Split View, Stage Manager, and rotation
/// all change the width, not the idiom. Compact (phone-like) grids stop at
/// three columns so artwork stays large; accessibility text sizes raise the
/// minimum tile width so titles keep room, down to a single column.
nonisolated struct LibraryGridMetrics: Equatable {
    static let compactColumnLimit = 3

    let columnCount: Int
    let tileWidth: Double
    let columnSpacing: Double
    let rowSpacing: Double
    let horizontalMargin: Double
    let isCompact: Bool

    static func resolve(
        containerWidth: Double,
        isCompact: Bool,
        isAccessibilitySize: Bool
    ) -> Self {
        let minimumTileWidth: Double
        let columnSpacing: Double
        let rowSpacing: Double
        let horizontalMargin: Double
        let columnLimit: Int
        if isCompact {
            minimumTileWidth = isAccessibilitySize ? 150 : 100
            columnSpacing = 12
            rowSpacing = 18
            horizontalMargin = 20
            columnLimit = compactColumnLimit
        } else {
            minimumTileWidth = isAccessibilitySize ? 240 : 160
            columnSpacing = 16
            rowSpacing = 24
            horizontalMargin = 24
            columnLimit = .max
        }

        let availableWidth = max(containerWidth - horizontalMargin * 2, 0)
        let fittingColumns = Int(((availableWidth + columnSpacing) / (minimumTileWidth + columnSpacing)).rounded(.down))
        let columnCount = min(max(fittingColumns, 1), columnLimit)
        let tileWidth = max(
            ((availableWidth - columnSpacing * Double(columnCount - 1)) / Double(columnCount)).rounded(.down),
            0
        )
        return Self(
            columnCount: columnCount,
            tileWidth: tileWidth,
            columnSpacing: columnSpacing,
            rowSpacing: rowSpacing,
            horizontalMargin: horizontalMargin,
            isCompact: isCompact
        )
    }

    var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: columnSpacing, alignment: .top),
            count: columnCount
        )
    }
}
