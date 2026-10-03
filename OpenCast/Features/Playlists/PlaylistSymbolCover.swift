import SwiftUI

/// A smart playlist's cover when no matched show has artwork: its tint as a
/// soft top-to-bottom gradient with its symbol large and white. Like
/// `PlaylistArtworkMosaic`, it fills the square it is offered; callers set
/// the size and corner radius.
struct PlaylistSymbolCover: View {
    static let defaultSymbolName = "sparkles"
    private static let symbolInsetFraction = 0.28

    let tint: PlaylistTint
    let symbolName: String?
    let cornerRadius: Double

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                PlaylistTintGradient(tint: tint)
            }
            .overlay {
                GeometryReader { proxy in
                    symbol(side: max(min(proxy.size.width, proxy.size.height), 0))
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
            .clipShape(.rect(cornerRadius: cornerRadius))
            .accessibilityHidden(true)
    }

    private func symbol(side: Double) -> some View {
        Image(systemName: symbolName ?? Self.defaultSymbolName)
            .resizable()
            .scaledToFit()
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
            .padding(side * Self.symbolInsetFraction)
            .frame(width: side, height: side)
    }
}

#Preview {
    HStack(spacing: 16) {
        PlaylistSymbolCover(tint: .indigo, symbolName: nil, cornerRadius: 14)
            .frame(width: 160, height: 160)
        PlaylistSymbolCover(tint: .yellow, symbolName: nil, cornerRadius: 12)
            .frame(width: 110, height: 110)
        PlaylistSymbolCover(tint: .teal, symbolName: nil, cornerRadius: 8)
            .frame(width: 56, height: 56)
    }
    .padding()
}
