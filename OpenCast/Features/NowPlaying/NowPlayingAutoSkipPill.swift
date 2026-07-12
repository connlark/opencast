import SwiftUI

struct NowPlayingAutoSkipPill: View {
    let onUndo: () -> Void

    var body: some View {
        Button(action: onUndo) {
            HStack(spacing: 6) {
                Label("Skipped promo", systemImage: "forward.end.fill")
                Text("Tap to undo")
                    .foregroundStyle(.white.opacity(0.82))
            }
            .font(.footnote)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(.white)
            .background(.red, in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Skipped promo. Undo.")
        .accessibilityIdentifier("Skipped promo")
    }
}
