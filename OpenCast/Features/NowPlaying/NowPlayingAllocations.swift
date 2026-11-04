import SwiftUI

/// Where the player and, beside it, the secondary pane sit on the Now
/// Playing surface, in its space (the window's for a foldable scene), x
/// leading-relative.
///
/// - `card` and `single`: the player takes the surface (the tall display's
///   pane is a row inside the player's stack).
/// - `split`: inside the safe rectangle, the player on the band's leading
///   side and the pane on its trailing side; the player takes the wider side
///   instead when the leading one cannot hold the transport. With no band,
///   an even split.
nonisolated struct NowPlayingAllocations: Equatable, Sendable {
    /// The widest transport at a non-accessibility size (two 76 pt skip
    /// buttons, the 96 pt play button and two 42 pt gaps) inside the regular
    /// card's 36 pt side paddings.
    static let minimumPlayerWidth: CGFloat = 76 + 42 + 96 + 42 + 76 + 2 * 36

    let player: CGRect
    /// Nil when the arrangement shows no pane beside the player.
    let pane: CGRect?

    init(arrangement: NowPlayingArrangement, bounds: CGSize, safeAreaInsets: EdgeInsets) {
        guard case .split(let band) = arrangement else {
            player = CGRect(origin: .zero, size: bounds)
            pane = nil
            return
        }
        let safe = CGRect(
            x: safeAreaInsets.leading,
            y: safeAreaInsets.top,
            width: max(0, bounds.width - safeAreaInsets.leading - safeAreaInsets.trailing),
            height: max(0, bounds.height - safeAreaInsets.top - safeAreaInsets.bottom)
        )
        guard let band, NowPlayingCardGeometry.overlaps(safe.minX...safe.maxX, band.minX...band.maxX) else {
            let half = safe.width / 2
            player = CGRect(x: safe.minX, y: safe.minY, width: half, height: safe.height)
            pane = CGRect(x: safe.minX + half, y: safe.minY, width: safe.width - half, height: safe.height)
            return
        }
        let leading = CGRect(x: safe.minX, y: safe.minY, width: max(0, band.minX - safe.minX), height: safe.height)
        let trailing = CGRect(x: band.maxX, y: safe.minY, width: max(0, safe.maxX - band.maxX), height: safe.height)
        let playerLeads = leading.width >= Self.minimumPlayerWidth || leading.width >= trailing.width
        player = playerLeads ? leading : trailing
        pane = playerLeads ? trailing : leading
    }
}
