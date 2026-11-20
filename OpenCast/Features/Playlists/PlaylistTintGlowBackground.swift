import SwiftUI

struct PlaylistTintGlowBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    let tint: Color

    var body: some View {
        Color.clear
            .overlay {
                tint.aspectRatio(1, contentMode: .fit)
            }
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

#Preview("Dark") {
    Color.clear
        .background(alignment: .top) {
            PlaylistTintGlowBackground(tint: PlaylistTint.indigo.color)
        }
        .preferredColorScheme(.dark)
}

#Preview("Light") {
    Color.clear
        .background(alignment: .top) {
            PlaylistTintGlowBackground(tint: PlaylistTint.orange.color)
        }
        .preferredColorScheme(.light)
}
