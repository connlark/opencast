import SwiftUI

extension LibraryGridMetrics {
    /// The metrics for a grid filling `proxy`, with the band reserved for
    /// the window's pose (`reservedBand(for:)`). The regions are the proxy's
    /// own, so the band is already in the grid's space. The proxy is laid out
    /// inside the safe area, so its width is the content's extent; the
    /// safe-area insets it reports lie outside it (A1: the safe reader is
    /// 867 pt wide in Book and still reports the 84 pt rail inset).
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
    /// Places a grid split around a fold band at its fixed width and offset;
    /// a full-width grid is unchanged.
    func libraryGridPlacement(_ metrics: LibraryGridMetrics) -> some View {
        frame(width: metrics.foldedGridWidth, alignment: .leading)
            .padding(.leading, metrics.foldSplit?.leadingOffset ?? 0)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
