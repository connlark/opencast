import SwiftUI

/// `cardFrame` and the allocation are in the window reader's space; every other value is
/// card-local. x is leading-relative, so a right-to-left layout mirrors the whole card.
nonisolated struct NowPlayingCardGeometry: Equatable {
    static let moreDiameter: CGFloat = 44
    static let foldClearance: CGFloat = 16

    private static let compactMoreTop: CGFloat = 62
    private static let regularMoreClearance: CGFloat = 18
    private static let moreSideClearance: CGFloat = 20
    private static let toastBelowMore: CGFloat = 48
    private static let toastSideClearance: CGFloat = 16

    let cardFrame: CGRect
    let contentInsets: EdgeInsets
    let contentTopPadding: CGFloat
    /// From the card's top edge, not the safe top: the safe area does not move the artwork bound.
    let artworkBoundTopPadding: CGFloat
    let contentBottomPadding: CGFloat
    let contentBottomClearance: CGFloat
    let moreIsLeading: Bool
    let moreOrigin: CGPoint
    let toastLeadingPadding: CGFloat
    let toastTrailingPadding: CGFloat
    let occlusions: [CGRect]
    /// No interactive control in the stack starts above this.
    let controlsMinY: CGFloat
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
            // The clearance counts from the safe top and the artwork bound from the card's top:
            // the tall phone's 150 below its 62 pt inset is 88.
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

    private static func safeInsets(card: CGRect, windowSize: CGSize, safeAreaInsets: EdgeInsets) -> EdgeInsets {
        EdgeInsets(
            top: max(0, safeAreaInsets.top - card.minY),
            leading: max(0, safeAreaInsets.leading - card.minX),
            bottom: max(0, card.maxY - (windowSize.height - safeAreaInsets.bottom)),
            trailing: max(0, card.maxX - (windowSize.width - safeAreaInsets.trailing))
        )
    }

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
