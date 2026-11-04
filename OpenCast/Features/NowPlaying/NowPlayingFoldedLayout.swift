import CoreGraphics

/// One card across a horizontal band (Laptop), card-local: the media (the
/// artwork and the title block) in the viewport above the band, the controls
/// (progress, the failure block, transport, the utility row and the pane's
/// row) in the viewport below it. Each viewport scrolls on its own and is
/// clipped at the band, so nothing scrolls through the fold. The artwork
/// fits the upper viewport after the title block, the spacing and the
/// paddings, each counted once; at accessibility sizes it keeps its bound
/// and the upper viewport scrolls instead.
struct NowPlayingFoldedLayout {
    let mediaViewport: ClosedRange<CGFloat>
    let controlsViewport: ClosedRange<CGFloat>
    let mediaTopPadding: CGFloat
    let mediaBottomPadding: CGFloat
    let controlsTopPadding: CGFloat
    let controlsBottomPadding: CGFloat
    let artworkSize: CGFloat
    /// The media at rest, once the title block is measured.
    let mediaSpan: ClosedRange<CGFloat>?
    /// The controls at rest, once they are measured (without an expanded pane).
    let controlsSpan: ClosedRange<CGFloat>?
    /// The room the controls leave below them, for the source pill's rule.
    let controlsSpareHeight: CGFloat?
    let mediaRequiresScrolling: Bool
    let controlsRequireScrolling: Bool

    init(
        cardHeight: CGFloat,
        fold: ClosedRange<CGFloat>,
        cardGeometry: NowPlayingCardGeometry,
        artworkUpperBound: CGFloat,
        contentSpacing: CGFloat,
        isAccessibilitySize: Bool,
        titleBlockHeight: CGFloat?,
        controlsHeight: CGFloat?,
        expandedPaneHeight: CGFloat = 0
    ) {
        let clearance = NowPlayingCardGeometry.foldClearance
        let media = 0...max(0, min(cardHeight, fold.lowerBound))
        let controls = min(cardHeight, max(0, fold.upperBound))...cardHeight
        let mediaTop = cardGeometry.contentTopPadding
        let controlsBottom = cardGeometry.contentBottomPadding
        let mediaHeight = media.upperBound - media.lowerBound
        let controlsViewportHeight = controls.upperBound - controls.lowerBound

        let room = mediaHeight - mediaTop - clearance - (titleBlockHeight ?? 0) - contentSpacing
        let artwork = NowPlayingContentMetrics.fittedArtworkSize(
            upperBound: artworkUpperBound,
            room: room,
            isAccessibilitySize: isAccessibilitySize
        )

        mediaViewport = media
        controlsViewport = controls
        mediaTopPadding = mediaTop
        mediaBottomPadding = clearance
        controlsTopPadding = clearance
        controlsBottomPadding = controlsBottom
        artworkSize = artwork
        mediaSpan = titleBlockHeight.map { mediaTop...(mediaTop + artwork + contentSpacing + $0) }
        controlsSpan = controlsHeight.map {
            (controls.lowerBound + clearance)...(controls.lowerBound + clearance + $0)
        }
        controlsSpareHeight = controlsHeight.map {
            controlsViewportHeight - clearance - $0 - expandedPaneHeight - controlsBottom
        }
        let mediaContentHeight = mediaTop + artwork + contentSpacing + (titleBlockHeight ?? 0) + clearance
        mediaRequiresScrolling = mediaContentHeight > mediaHeight + 0.5
        controlsRequireScrolling = controlsSpareHeight.map { $0 < -0.5 } ?? false
    }

    var mediaViewportHeight: CGFloat {
        mediaViewport.upperBound - mediaViewport.lowerBound
    }

    var controlsViewportHeight: CGFloat {
        controlsViewport.upperBound - controlsViewport.lowerBound
    }

    /// The band between the viewports, where nothing is drawn.
    var foldGap: CGFloat {
        max(0, controlsViewport.lowerBound - mediaViewport.upperBound)
    }
}
