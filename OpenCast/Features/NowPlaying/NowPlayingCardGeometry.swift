import SwiftUI

/// Where the Now Playing card and its fixed chrome sit, with each window
/// inset applied once. The inputs, an allocation and `cardFrame` are in the
/// window reader's space; every other value is card-local. x is measured
/// from the leading edge throughout: the reserved regions' default `.mirrors`
/// behaviour and SwiftUI's leading padding agree on it, so a right-to-left
/// layout mirrors the whole card.
nonisolated struct NowPlayingCardGeometry: Equatable {
    /// The More button's frame (`NowPlayingMoreMenu`).
    static let moreDiameter: CGFloat = 44
    /// The fold band's clearance from the title block and the progress section.
    static let foldClearance: CGFloat = 16

    /// A full-screen card's More row starts 62 pt below the window's top edge,
    /// or at the safe top when that is lower.
    private static let compactMoreTop: CGFloat = 62
    /// The regular card sits below the window's top inset, so its More counts
    /// from its own safe top.
    private static let regularMoreClearance: CGFloat = 18
    private static let moreSideClearance: CGFloat = 20
    /// The toasts start this far below More's top.
    private static let toastBelowMore: CGFloat = 48
    private static let toastSideClearance: CGFloat = 16

    let cardFrame: CGRect
    /// The part of the window's safe area the card overlaps. A compact card's
    /// content keeps the card's full width, so its sides are zero there.
    let contentInsets: EdgeInsets
    /// Where the content's stack starts: the safe top, then the content's own
    /// top clearance.
    let contentTopPadding: CGFloat
    /// Today's top padding, measured from the card's top edge: the basis of the
    /// artwork's upper bound, which the safe area does not move.
    let artworkBoundTopPadding: CGFloat
    /// The safe bottom (or a bottom occlusion region), then
    /// `contentBottomClearance`.
    let contentBottomPadding: CGFloat
    /// The content's own bottom clearance.
    let contentBottomClearance: CGFloat
    /// More sits top-trailing as it always has, and moves to the top-leading
    /// corner only where an active occlusion region covers the top-trailing
    /// one (the iPhone Duo's outer display, where the status cluster sits).
    let moreIsLeading: Bool
    /// More's top-left corner in leading-relative coordinates.
    let moreOrigin: CGPoint
    let toastLeadingPadding: CGFloat
    let toastTrailingPadding: CGFloat
    /// The active occlusion regions that reach the card, card-local.
    let occlusions: [CGRect]
    /// No interactive control in the stack starts above this: the lowest
    /// bottom edge of the occlusion regions over the top of the content.
    let controlsMinY: CGFloat
    /// Laptop's band across the card, as card-local y.
    let horizontalFold: ClosedRange<CGFloat>?

    init(
        windowSize: CGSize,
        safeAreaInsets: EdgeInsets,
        isRegular: Bool,
        isAccessibilitySize: Bool,
        pose: WindowPose,
        occlusions: [CGRect]
    ) {
        self.init(
            cardFrame: Self.placeCard(windowSize: windowSize, isRegular: isRegular, pose: pose),
            windowSize: windowSize,
            safeAreaInsets: safeAreaInsets,
            isRegular: isRegular,
            isAccessibilitySize: isAccessibilitySize,
            pose: pose,
            occlusions: occlusions
        )
    }

    /// The player in a window-sized surface: the whole window for one card,
    /// or the half a split gives it. Regular metrics inside the allocation;
    /// a vertical band across it confines the card to the band's leading side
    /// (its trailing side when nothing of the allocation is leading).
    init(
        allocation: CGRect,
        windowSize: CGSize,
        safeAreaInsets: EdgeInsets,
        isAccessibilitySize: Bool,
        pose: WindowPose,
        occlusions: [CGRect]
    ) {
        self.init(
            cardFrame: Self.confine(allocation, pose: pose),
            windowSize: windowSize,
            safeAreaInsets: safeAreaInsets,
            isRegular: true,
            isAccessibilitySize: isAccessibilitySize,
            pose: pose,
            occlusions: occlusions
        )
    }

    private init(
        cardFrame: CGRect,
        windowSize: CGSize,
        safeAreaInsets: EdgeInsets,
        isRegular: Bool,
        isAccessibilitySize: Bool,
        pose: WindowPose,
        occlusions: [CGRect]
    ) {
        let card = CGRect(origin: .zero, size: cardFrame.size)
        let safe = Self.safeInsets(card: cardFrame, windowSize: windowSize, safeAreaInsets: safeAreaInsets)
        let regions = occlusions
            .map { $0.offsetBy(dx: -cardFrame.minX, dy: -cardFrame.minY) }
            .filter { Self.overlaps($0, card) }
        let contentInsets = isRegular
            ? safe
            : EdgeInsets(top: safe.top, leading: 0, bottom: safe.bottom, trailing: 0)
        let contentSpan = contentInsets.leading...max(contentInsets.leading, card.width - contentInsets.trailing)
        let spanRegions = regions.filter { Self.overlaps($0.minX...$0.maxX, contentSpan) }
        let topRegions = spanRegions.filter { $0.midY < card.midY }
        let bottomRegionTop = spanRegions.filter { $0.midY >= card.midY }.map(\.minY).min()

        let bottomInset = max(safe.bottom, bottomRegionTop.map { card.height - $0 } ?? 0)
        let bottomClearance: CGFloat = isRegular ? 32 : 22
        contentBottomClearance = bottomClearance
        contentBottomPadding = bottomInset + bottomClearance

        let moreTop: CGFloat
        if isRegular {
            let clearance: CGFloat = isAccessibilitySize ? 56 : 96
            artworkBoundTopPadding = clearance
            contentTopPadding = safe.top + clearance
            moreTop = safe.top + Self.regularMoreClearance
        } else {
            let isShort = card.height < (isAccessibilitySize ? 700 : 720)
            // Today's 92 / 150 were measured from the window's top with the
            // status bar inside them; below the safe top the tall phone's 150
            // is 88 (its 62 pt inset). The accessibility values were already
            // meant below the safe top.
            let clearance: CGFloat = if isAccessibilitySize {
                isShort ? 14 : 28
            } else {
                isShort ? 92 : 88
            }
            artworkBoundTopPadding = if isAccessibilitySize {
                isShort ? 14 : 28
            } else {
                isShort ? 92 : 150
            }
            contentTopPadding = safe.top + clearance
            moreTop = max(safe.top, Self.compactMoreTop)
        }

        let moreSize = CGSize(width: Self.moreDiameter, height: Self.moreDiameter)
        let todaysMoreFrame = CGRect(
            origin: CGPoint(x: card.width - Self.moreSideClearance - Self.moreDiameter, y: moreTop),
            size: moreSize
        )
        let moreIsLeading = regions.contains { Self.overlaps($0, todaysMoreFrame) }
        let moreX = moreIsLeading
            ? safe.leading + Self.moreSideClearance
            : card.width - safe.trailing - Self.moreSideClearance - Self.moreDiameter
        let moreFrame = Self.below(regions, CGRect(origin: CGPoint(x: moreX, y: moreTop), size: moreSize))

        self.cardFrame = cardFrame
        self.contentInsets = contentInsets
        self.moreIsLeading = moreIsLeading
        moreOrigin = moreFrame.origin
        toastLeadingPadding = safe.leading + Self.toastSideClearance
        toastTrailingPadding = safe.trailing + Self.toastSideClearance
        self.occlusions = regions
        controlsMinY = topRegions.map(\.maxY).max() ?? 0
        horizontalFold = if case .foldedHorizontal = pose,
                            let band = pose.band(inConsumerFrame: cardFrame),
                            Self.overlaps(band.minY...band.maxY, 0...card.height) {
            band.minY...band.maxY
        } else {
            nil
        }
    }

    /// The toasts' top edge for a toast of the measured height: 48 pt below
    /// More's top, moved below any occlusion region the toast would overlap.
    func toastTop(height: CGFloat) -> CGFloat {
        Self.below(
            occlusions,
            CGRect(
                x: toastLeadingPadding,
                y: moreOrigin.y + Self.toastBelowMore,
                width: max(0, cardFrame.width - toastLeadingPadding - toastTrailingPadding),
                height: height
            )
        ).minY
    }

    /// A compact card is the window. A regular card keeps today's size,
    /// bottom-aligned and centred in the window, or in Book in the band's
    /// leading side.
    private static func placeCard(windowSize: CGSize, isRegular: Bool, pose: WindowPose) -> CGRect {
        guard isRegular else {
            return CGRect(origin: .zero, size: windowSize)
        }
        let span: ClosedRange<CGFloat> = if case .foldedVertical(let band) = pose {
            0...max(0, band.minX)
        } else {
            0...windowSize.width
        }
        let spanWidth = span.upperBound - span.lowerBound
        let width = (spanWidth - 80).clamped(to: 0...660)
        let height = (windowSize.height - 72).clamped(to: 0...860)
        return CGRect(
            x: span.lowerBound + (spanWidth - width) / 2,
            y: windowSize.height - height,
            width: width,
            height: height
        )
    }

    /// The part of an allocation clear of a vertical band: the leading side,
    /// or the trailing side when the allocation has nothing leading of it.
    private static func confine(_ allocation: CGRect, pose: WindowPose) -> CGRect {
        guard case .foldedVertical(let band) = pose,
              overlaps(allocation.minX...allocation.maxX, band.minX...band.maxX)
        else {
            return allocation
        }
        if band.minX > allocation.minX {
            return CGRect(x: allocation.minX, y: allocation.minY, width: band.minX - allocation.minX, height: allocation.height)
        }
        return CGRect(
            x: band.maxX,
            y: allocation.minY,
            width: max(0, allocation.maxX - band.maxX),
            height: allocation.height
        )
    }

    /// The window's safe insets as they fall on the card: zero where the card
    /// already sits inside the safe rectangle.
    private static func safeInsets(card: CGRect, windowSize: CGSize, safeAreaInsets: EdgeInsets) -> EdgeInsets {
        EdgeInsets(
            top: max(0, safeAreaInsets.top - card.minY),
            leading: max(0, safeAreaInsets.leading - card.minX),
            bottom: max(0, card.maxY - (windowSize.height - safeAreaInsets.bottom)),
            trailing: max(0, card.maxX - (windowSize.width - safeAreaInsets.trailing))
        )
    }

    /// Moves `frame` down below every region it overlaps.
    private static func below(_ regions: [CGRect], _ frame: CGRect) -> CGRect {
        var frame = frame
        while let region = regions.first(where: { overlaps($0, frame) }) {
            frame.origin.y = region.maxY
        }
        return frame
    }

    /// Strict overlap: rectangles that only share an edge do not overlap.
    static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        overlaps(a.minX...a.maxX, b.minX...b.maxX) && overlaps(a.minY...a.maxY, b.minY...b.maxY)
    }

    static func overlaps(_ a: ClosedRange<CGFloat>, _ b: ClosedRange<CGFloat>) -> Bool {
        a.lowerBound < b.upperBound && b.lowerBound < a.upperBound
    }
}
