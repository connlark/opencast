import SwiftUI

struct NowPlayingSoundLabControlIcon: View {
    let systemImage: String
    let tint: Color

    var body: some View {
        Image(systemName: systemImage)
            .symbolRenderingMode(.monochrome)
            .resizable()
            .scaledToFit()
            .foregroundStyle(.white)
            .frame(width: 14, height: 14)
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
