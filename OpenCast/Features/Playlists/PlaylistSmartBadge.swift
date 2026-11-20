import SwiftUI

/// Scales with the cover, not Dynamic Type: the 56 pt list thumbnail cannot grow with the
/// text. Decorative, since the summary and meta lines already say "Smart" to VoiceOver.
struct PlaylistSmartBadge: View {
    let tint: PlaylistTint
    let coverSide: Double

    var body: some View {
        let glyphSide = min(max(coverSide * 0.105, 7), 16)
        Image(systemName: "sparkles")
            .resizable()
            .scaledToFit()
            .frame(width: glyphSide, height: glyphSide)
            .foregroundStyle(tint.color)
            .padding(glyphSide * 0.5)
            .glassEffect(.regular, in: .circle)
            .padding(max(coverSide * 0.05, 3))
            .accessibilityHidden(true)
    }
}
