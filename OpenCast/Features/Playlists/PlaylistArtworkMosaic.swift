import SwiftUI

/// A playlist's cover: its shows' artwork in a 2x2 mosaic with 1 pt seams,
/// a single cover for one show, and the name's initials for none. It fills
/// the square it is offered; callers set the size and corner radius.
struct PlaylistArtworkMosaic: View {
    private static let seamWidth = 1.0
    // ArtworkPlaceholder clips every image to 8 pt corners. Drawing each
    // mosaic cell slightly larger and cropping it square pushes those
    // corners outside the cell, so the seams stay straight.
    private static let cellBleed = 3.0

    let sources: PlaylistCoverSources
    let cornerRadius: Double

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                GeometryReader { proxy in
                    cover(side: max(min(proxy.size.width, proxy.size.height), 0))
                }
            }
            .clipShape(.rect(cornerRadius: cornerRadius))
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func cover(side: Double) -> some View {
        let slots = mosaicSlots
        if slots.count == 4 {
            let cellSide = max((side - Self.seamWidth) / 2, 0)
            Grid(horizontalSpacing: Self.seamWidth, verticalSpacing: Self.seamWidth) {
                GridRow {
                    cell(slots[0], side: cellSide)
                    cell(slots[1], side: cellSide)
                }
                GridRow {
                    cell(slots[2], side: cellSide)
                    cell(slots[3], side: cellSide)
                }
            }
        } else {
            ArtworkPlaceholder(
                title: sources.fallbackTitle,
                imageURL: sources.artworkURLs.first?.absoluteString,
                size: side
            )
        }
    }

    private func cell(_ url: URL, side: Double) -> some View {
        ArtworkPlaceholder(
            title: sources.fallbackTitle,
            imageURL: url.absoluteString,
            size: side + Self.cellBleed * 2
        )
        .frame(width: side, height: side)
        .clipped()
    }

    /// Four slots for two or more shows: three repeat the first in the last
    /// slot, two alternate as a checkerboard. Fewer than two shows draw a
    /// single cover instead.
    private var mosaicSlots: [URL] {
        let urls = Array(sources.artworkURLs.prefix(PlaylistCoverSources.maximumArtworkCount))
        switch urls.count {
        case 4:
            return urls
        case 3:
            return [urls[0], urls[1], urls[2], urls[0]]
        case 2:
            return [urls[0], urls[1], urls[1], urls[0]]
        default:
            return []
        }
    }
}
