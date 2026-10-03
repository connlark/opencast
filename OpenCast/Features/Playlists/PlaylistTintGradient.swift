import SwiftUI

/// A smart playlist's tint as a soft top-to-bottom gradient: the ground of
/// its symbol cover and of its card stack.
struct PlaylistTintGradient: View {
    let tint: PlaylistTint

    var body: some View {
        LinearGradient(
            colors: [tint.color.mix(with: .white, by: 0.22), tint.color.mix(with: .black, by: 0.12)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}
