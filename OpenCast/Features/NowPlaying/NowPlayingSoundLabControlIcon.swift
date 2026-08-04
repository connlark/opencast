import SwiftUI

struct NowPlayingSoundLabControlIcon: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let systemImage: String
    let tint: Color

    var body: some View {
        Image(systemName: systemImage)
            .symbolRenderingMode(.monochrome)
            .resizable()
            .scaledToFit()
            .foregroundStyle(.white)
            .frame(width: 14, height: 14)
            .contentTransition(.symbolEffect(.replace))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: systemImage)
            .frame(
                width: NowPlayingSoundLabLayout.controlIconDiameter,
                height: NowPlayingSoundLabLayout.controlIconDiameter
            )
            .background {
                Circle()
                    .fill(tint.gradient)
                    .overlay {
                        Circle()
                            .stroke(.white.opacity(0.22), lineWidth: 0.75)
                    }
            }
            .animation(.easeOut(duration: 0.18), value: tint)
            .accessibilityHidden(true)
    }
}
