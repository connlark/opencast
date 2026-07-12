import SwiftUI

/// Blurred artwork-preview glow pinned behind the top of the episode detail
/// scroll view, extending under the navigation bar to the screen edge.
struct EpisodeArtworkGlowBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    let preview: ArtworkPreview?

    var body: some View {
        if let preview {
            ArtworkPreviewImage(preview: preview)
                .blur(radius: 60)
                .opacity(colorScheme == .dark ? 0.45 : 0.28)
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: 0.6),
                            .init(color: .clear, location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .containerRelativeFrame(.vertical) { length, _ in
                    length * 0.55
                }
                .ignoresSafeArea(edges: .top)
                .accessibilityHidden(true)
        }
    }
}

#Preview("Dark") {
    Color.clear
        .background(alignment: .top) {
            EpisodeArtworkGlowBackground(preview: .previewSample)
        }
        .preferredColorScheme(.dark)
}

#Preview("Light") {
    Color.clear
        .background(alignment: .top) {
            EpisodeArtworkGlowBackground(preview: .previewSample)
        }
        .preferredColorScheme(.light)
}
