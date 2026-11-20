import SwiftUI

extension LibraryGridMetrics {
    /// The proxy sits inside the safe area: its width is already the content's extent, and the
    /// safe-area insets it reports lie outside it.
    static func resolve(
        in proxy: GeometryProxy,
        horizontalSizeClass: UserInterfaceSizeClass?,
        verticalSizeClass: UserInterfaceSizeClass?,
        isAccessibilitySize: Bool
    ) -> Self {
        let pose = WindowPose(
            horizontalSizeClass: horizontalSizeClass,
            divisionRegions: WindowDivisionRegion.current(in: proxy)
        )
        return resolve(
            containerWidth: proxy.size.width,
            isCompact: horizontalSizeClass == .compact || verticalSizeClass == .compact,
            isAccessibilitySize: isAccessibilitySize,
            reservedBand: reservedBand(for: pose)
        )
    }
}

extension View {
    func libraryGridPlacement(_ metrics: LibraryGridMetrics) -> some View {
        frame(width: metrics.foldedGridWidth, alignment: .leading)
            .padding(.leading, metrics.foldSplit?.leadingOffset ?? 0)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
