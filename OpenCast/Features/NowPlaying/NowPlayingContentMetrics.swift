import SwiftUI

struct NowPlayingContentMetrics {
    /// The fit rule never shrinks the artwork below this.
    static let minimumArtworkSize: CGFloat = 64

    /// Today's bounds: the content width, a share of the height, and a cap.
    let artworkUpperBound: CGFloat
    /// The fit rule applied to the measured rows; the
    /// upper bound until they are measured.
    let artworkSize: CGFloat
    let contentWidth: CGFloat
    let containerHeight: CGFloat
    let leadingPadding: CGFloat
    let trailingPadding: CGFloat
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
    /// Above the title block: moves it and everything below it past Laptop's
    /// fold band when the title block or the progress section would cross it.
    let titleBlockTopSpacer: CGFloat
    /// Above the progress section: keeps the first interactive row clear of
    /// the occlusion regions over the top of the card.
    let progressSectionTopSpacer: CGFloat
    /// The laid-out height of the padded stack, once the rows are measured.
    let stackHeight: CGFloat?
    /// Card-local y ranges at rest, once the title block and the progress
    /// section are measured.
    let titleBlockSpan: ClosedRange<CGFloat>?
    let progressSectionSpan: ClosedRange<CGFloat>?
    /// Laptop's band across the card, card-local y.
    let horizontalFold: ClosedRange<CGFloat>?

    init(
        containerSize: CGSize,
        cardGeometry: NowPlayingCardGeometry,
        dynamicTypeSize: DynamicTypeSize,
        horizontalSizeClass: UserInterfaceSizeClass?,
        measurements: NowPlayingContentMeasurements
    ) {
        let isAccessibilitySize = dynamicTypeSize.isAccessibilitySize
        let isRegular = horizontalSizeClass == .regular
        let horizontalPadding: CGFloat = isRegular ? 36 : 24
        let leadingPadding = cardGeometry.contentInsets.leading + horizontalPadding
        let trailingPadding = cardGeometry.contentInsets.trailing + horizontalPadding
        let topContentPadding = cardGeometry.contentTopPadding
        let bottomContentPadding = cardGeometry.contentBottomPadding
        let availableWidth = max(containerSize.width - leadingPadding - trailingPadding, 0)
        // Today's height share, on today's padding basis (the card's own
        // clearances): the safe insets cost the fit rule below, not this bound.
        let availableHeight = max(
            containerSize.height - cardGeometry.artworkBoundTopPadding - cardGeometry.contentBottomClearance,
            280
        )
        let heightConstraintFactor: CGFloat = if isAccessibilitySize {
            isRegular ? 0.30 : 0.26
        } else {
            isRegular ? 0.46 : 0.40
        }
        let artworkCap: CGFloat = if isAccessibilitySize {
            Self.accessibilityArtworkCap(containerHeight: containerSize.height, isRegular: isRegular)
        } else {
            isRegular ? 360 : 300
        }
        let artworkUpperBound = min(availableWidth, availableHeight * heightConstraintFactor, artworkCap)
        let contentSpacing: CGFloat = isAccessibilitySize ? 14 : 12

        let artworkSize: CGFloat = if let rowsHeight = measurements.rowsHeight {
            Self.fittedArtworkSize(
                upperBound: artworkUpperBound,
                room: containerSize.height - topContentPadding - bottomContentPadding - rowsHeight,
                isAccessibilitySize: isAccessibilitySize
            )
        } else {
            artworkUpperBound
        }

        var titleBlockTopSpacer: CGFloat = 0
        var progressSectionTopSpacer: CGFloat = 0
        var titleBlockSpan: ClosedRange<CGFloat>?
        var progressSectionSpan: ClosedRange<CGFloat>?
        if let titleBlockHeight = measurements.titleBlockHeight,
           let progressSectionHeight = measurements.progressSectionHeight {
            let titleTop = topContentPadding + artworkSize + contentSpacing
            func progressSpacer(titleSpacer: CGFloat) -> CGFloat {
                max(0, cardGeometry.controlsMinY - (titleTop + titleSpacer + titleBlockHeight + contentSpacing))
            }
            progressSectionTopSpacer = progressSpacer(titleSpacer: 0)
            let blockBottom = titleTop + titleBlockHeight + contentSpacing
                + progressSectionTopSpacer + progressSectionHeight
            titleBlockTopSpacer = Self.foldSpacer(for: titleTop...blockBottom, fold: cardGeometry.horizontalFold)
            if titleBlockTopSpacer > 0 {
                progressSectionTopSpacer = progressSpacer(titleSpacer: titleBlockTopSpacer)
            }
            let titleBlockTop = titleTop + titleBlockTopSpacer
            let progressTop = titleBlockTop + titleBlockHeight + contentSpacing + progressSectionTopSpacer
            titleBlockSpan = titleBlockTop...(titleBlockTop + titleBlockHeight)
            progressSectionSpan = progressTop...(progressTop + progressSectionHeight)
        }

        self.artworkUpperBound = artworkUpperBound
        self.artworkSize = artworkSize
        contentWidth = min(availableWidth, isRegular ? 500 : 430)
        containerHeight = containerSize.height
        self.leadingPadding = leadingPadding
        self.trailingPadding = trailingPadding
        self.topContentPadding = topContentPadding
        self.bottomContentPadding = bottomContentPadding
        self.contentSpacing = contentSpacing
        metadataSpacing = 6
        titleFont = isAccessibilitySize ? .headline : .title2
        podcastFont = isAccessibilitySize ? .subheadline : .title3
        titleLineLimit = isAccessibilitySize ? 3 : 2
        podcastLineLimit = isAccessibilitySize ? 2 : 1
        titleMinimumScaleFactor = isAccessibilitySize ? 0.92 : 0.78
        podcastMinimumScaleFactor = isAccessibilitySize ? 0.9 : 0.82
        self.titleBlockTopSpacer = titleBlockTopSpacer
        self.progressSectionTopSpacer = progressSectionTopSpacer
        stackHeight = measurements.rowsHeight.map {
            topContentPadding + artworkSize + titleBlockTopSpacer + progressSectionTopSpacer + $0 + bottomContentPadding
        }
        self.titleBlockSpan = titleBlockSpan
        self.progressSectionSpan = progressSectionSpan
        horizontalFold = cardGeometry.horizontalFold
    }

    /// The finished card's title block sits under the upper-bound artwork and
    /// keeps off Laptop's band the same way.
    func finishedTitleBlockTopSpacer(titleBlockHeight: CGFloat?) -> CGFloat {
        guard let titleBlockHeight else {
            return 0
        }
        let titleTop = topContentPadding + artworkUpperBound + contentSpacing
        return Self.foldSpacer(for: titleTop...(titleTop + titleBlockHeight), fold: horizontalFold)
    }

    /// How far a block (card-local y, at rest) moves down to clear Laptop's
    /// band and its clearance; 0 when it does not cross them. Content that
    /// scrolls passes the band like any fixed region; the layout at rest is
    /// what keeps clear of it.
    static func foldSpacer(for block: ClosedRange<CGFloat>, fold: ClosedRange<CGFloat>?) -> CGFloat {
        guard let fold else {
            return 0
        }
        let clearance = NowPlayingCardGeometry.foldClearance
        let guarded = (fold.lowerBound - clearance)...(fold.upperBound + clearance)
        return NowPlayingCardGeometry.overlaps(block, guarded) ? guarded.upperBound - block.lowerBound : 0
    }

    /// The utility row is the stack's last row, so it ends where the bottom
    /// padding begins.
    var utilityRowMaxY: CGFloat? {
        stackHeight.map { $0 - bottomContentPadding }
    }

    /// Past the artwork's floor the content scrolls; it never clips.
    var requiresScrolling: Bool {
        stackHeight.map { $0 > containerHeight + 0.5 } ?? false
    }

    /// The artwork gives way first: the smaller of its upper bound and the
    /// room the rows leave, never below `minimumArtworkSize`; past the floor
    /// the card scrolls. At accessibility sizes it keeps its upper bound: the
    /// stack scrolls on every phone there anyway, and the Sound Lab's panel,
    /// framed to the artwork, needs the room for its rows.
    static func fittedArtworkSize(upperBound: CGFloat, room: CGFloat, isAccessibilitySize: Bool) -> CGFloat {
        guard !isAccessibilitySize else {
            return upperBound
        }
        return min(upperBound, max(minimumArtworkSize, room))
    }

    private static func accessibilityArtworkCap(containerHeight: CGFloat, isRegular: Bool) -> CGFloat {
        if isRegular {
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
