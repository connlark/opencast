import SwiftUI

/// The small glass sparkles that marks a smart playlist's grid tile. It is
/// decorative: the tile's summary line already says "Smart playlist" to
/// VoiceOver.
struct PlaylistSmartBadge: View {
    let tint: PlaylistTint

    var body: some View {
        Image(systemName: "sparkles")
            .font(.caption)
            .foregroundStyle(tint.color)
            .padding(6)
            .glassEffect(.regular, in: .circle)
            .padding(6)
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .accessibilityHidden(true)
    }
}
