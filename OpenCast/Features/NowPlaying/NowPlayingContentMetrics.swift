import SwiftUI

struct NowPlayingContentMetrics {
    let artworkSize: CGFloat
    let contentWidth: CGFloat
    let containerHeight: CGFloat
    let horizontalPadding: CGFloat
    let topContentPadding: CGFloat
    let bottomContentPadding: CGFloat
    let contentSpacing: CGFloat
    let metadataSpacing: CGFloat
    let titleFont: Font
    let podcastFont: Font
    let titleLineLimit: Int
    let podcastLineLimit: Int
    let titleMinimumScaleFactor: CGFloat
    let podcastMinimumScaleFactor: CGFloat

    init(
        proxy: GeometryProxy,
        dynamicTypeSize: DynamicTypeSize,
        horizontalSizeClass: UserInterfaceSizeClass?,
        topContentPadding: CGFloat,
        bottomContentPadding: CGFloat
    ) {
        let isAccessibilitySize = dynamicTypeSize.isAccessibilitySize
        let horizontalPadding: CGFloat = horizontalSizeClass == .regular ? 36 : 24
        let availableWidth = proxy.size.width - horizontalPadding * 2
        let availableHeight = max(proxy.size.height - topContentPadding - bottomContentPadding, 280)
        let heightConstraintFactor: CGFloat = if isAccessibilitySize {
            horizontalSizeClass == .regular ? 0.30 : 0.26
        } else {
            horizontalSizeClass == .regular ? 0.46 : 0.40
        }
        let heightConstrainedWidth = availableHeight * heightConstraintFactor
        let artworkCap: CGFloat = if isAccessibilitySize {
            Self.accessibilityArtworkCap(
                containerHeight: proxy.size.height,
                horizontalSizeClass: horizontalSizeClass
            )
        } else {
            horizontalSizeClass == .regular ? 360 : 300
        }

        artworkSize = min(availableWidth, heightConstrainedWidth, artworkCap)
        contentWidth = min(availableWidth, horizontalSizeClass == .regular ? 500 : 430)
        containerHeight = proxy.size.height
        self.horizontalPadding = horizontalPadding
        self.topContentPadding = topContentPadding
        self.bottomContentPadding = bottomContentPadding
        contentSpacing = isAccessibilitySize ? 14 : 12
        metadataSpacing = 6
        titleFont = isAccessibilitySize ? .headline : .title2
        podcastFont = isAccessibilitySize ? .subheadline : .title3
        titleLineLimit = isAccessibilitySize ? 3 : 2
        podcastLineLimit = isAccessibilitySize ? 2 : 1
        titleMinimumScaleFactor = isAccessibilitySize ? 0.92 : 0.78
        podcastMinimumScaleFactor = isAccessibilitySize ? 0.9 : 0.82
    }

    private static func accessibilityArtworkCap(
        containerHeight: CGFloat,
        horizontalSizeClass: UserInterfaceSizeClass?
    ) -> CGFloat {
        if horizontalSizeClass == .regular {
            return 300
        }

        if containerHeight < 700 {
            return 188
        }

        if containerHeight < 780 {
            return 220
        }

        return 240
    }
}
