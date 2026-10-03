import SwiftUI

/// A smart playlist's cover from its shows' artwork, most dominant first:
/// two or three shows stack as cards on the playlist's tint with the
/// dominant show in front, one show fills the cover, and none falls back to
/// the tinted symbol tile. The sparkles badge sits at the top-leading corner
/// in every case, scaled to the cover, so a cover showing a podcast's art
/// still reads as smart. It fills the square it is offered; callers set the
/// size and corner radius.
struct PlaylistCardStackCover: View {
    // ArtworkPlaceholder clips every image to 8 pt corners. Drawing each card
    // slightly larger and cropping it pushes those corners outside the card,
    // so the card's own corner radius is the one that shows.
    private static let cardBleed = 3.0

    let artworkURLs: [URL]
    let fallbackTitle: String
    let tint: PlaylistTint
    let symbolName: String?
    let cornerRadius: Double

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                GeometryReader { proxy in
                    let side = max(min(proxy.size.width, proxy.size.height), 0)
                    cover(side: side)
                        .frame(width: side, height: side)
                        .overlay(alignment: .topLeading) {
                            PlaylistSmartBadge(tint: tint, coverSide: side)
                        }
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func cover(side: Double) -> some View {
        let urls = Array(artworkURLs.prefix(SmartPlaylistCoverSources.maximumShowCount))
        if urls.isEmpty {
            PlaylistSymbolCover(tint: tint, symbolName: symbolName, cornerRadius: cornerRadius)
        } else if urls.count == 1 {
            ArtworkPlaceholder(title: fallbackTitle, imageURL: urls[0].absoluteString, size: side)
                .clipShape(.rect(cornerRadius: cornerRadius))
        } else {
            ZStack {
                PlaylistTintGradient(tint: tint)
                ForEach(Array(urls.enumerated().reversed()), id: \.offset) { depth, url in
                    deckCard(url, depth: depth, count: urls.count, side: side)
                }
            }
            .frame(width: side, height: side)
            .clipShape(.rect(cornerRadius: cornerRadius))
        }
    }

    /// Back cards shrink and rise behind the front one, centred, so each
    /// peeks out above the card in front of it.
    private func deckCard(_ url: URL, depth: Int, count: Int, side: Double) -> some View {
        let frontSide = side * 0.68
        let step = side * 0.085
        let cardSide = frontSide * (1 - 0.12 * Double(depth))
        let frontTop = (side - frontSide) / 2 + step * Double(count - 1) / 2
        let top = frontTop - step * Double(depth)
        return card(url, depth: depth, cardSide: cardSide, coverSide: side)
            .position(x: side / 2, y: top + cardSide / 2)
    }

    private func card(_ url: URL, depth: Int, cardSide: Double, coverSide: Double) -> some View {
        let radius = max(cardSide * 0.09, 3)
        return ArtworkPlaceholder(
            title: fallbackTitle,
            imageURL: url.absoluteString,
            size: cardSide + Self.cardBleed * 2
        )
        .frame(width: cardSide, height: cardSide)
        .overlay {
            Color.black.opacity(0.14 * Double(depth))
        }
        .clipShape(.rect(cornerRadius: radius))
        .overlay {
            RoundedRectangle(cornerRadius: radius)
                .strokeBorder(.white.opacity(0.22), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.3), radius: coverSide * 0.03, y: coverSide * 0.012)
    }
}

#Preview {
    let urls = ["a", "b", "c"].compactMap { URL(string: "https://example.com/\($0).jpg") }
    VStack(spacing: 16) {
        HStack(spacing: 16) {
            PlaylistCardStackCover(artworkURLs: urls, fallbackTitle: "Fresh", tint: .indigo, symbolName: nil, cornerRadius: 14)
                .frame(width: 160, height: 160)
            PlaylistCardStackCover(artworkURLs: urls, fallbackTitle: "Fresh", tint: .orange, symbolName: nil, cornerRadius: 12)
                .frame(width: 112, height: 112)
            PlaylistCardStackCover(artworkURLs: urls, fallbackTitle: "Fresh", tint: .teal, symbolName: nil, cornerRadius: 8)
                .frame(width: 56, height: 56)
        }
        HStack(spacing: 16) {
            PlaylistCardStackCover(artworkURLs: Array(urls.prefix(1)), fallbackTitle: "One Show", tint: .purple, symbolName: nil, cornerRadius: 12)
                .frame(width: 112, height: 112)
            PlaylistCardStackCover(artworkURLs: [], fallbackTitle: "Empty", tint: .green, symbolName: nil, cornerRadius: 12)
                .frame(width: 112, height: 112)
        }
    }
    .padding()
}
