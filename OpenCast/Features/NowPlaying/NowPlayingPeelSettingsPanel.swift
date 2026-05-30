import SwiftUI

struct NowPlayingPeelSettingsPanel: View {
    let revealProgress: CGFloat
    @Binding var voiceBoostEnabled: Bool
    let voiceBoostControlEnabled: Bool

    var body: some View {
        GeometryReader { proxy in
            let contentInset = max(10, proxy.size.width * 0.04)
            let protectedLeadingSpace = max(108, proxy.size.width * 0.38)
            let rowSpacing = proxy.size.height > 290 ? 7.0 : 5.0

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(panelGradient)

                RoundedRectangle(cornerRadius: 8)
                    .stroke(.white.opacity(0.22), lineWidth: 1)

                VStack(spacing: 8) {
                    ForEach(0..<12, id: \.self) { _ in
                        Capsule()
                            .fill(.primary.opacity(0.13))
                            .frame(width: 3, height: 11)
                    }
                }
                .padding(.leading, contentInset + 8)
                .opacity(0.46 + 0.30 * Double(revealProgress))
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: rowSpacing) {
                    Label("Sound Lab", systemImage: "sparkles")
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .foregroundStyle(.primary)
                        .padding(.bottom, 2)

                    NowPlayingPeelSettingsToggle(
                        title: "Voice Boost",
                        systemImage: "waveform",
                        tint: .cyan,
                        isEnabled: voiceBoostControlEnabled,
                        isOn: $voiceBoostEnabled
                    )
                }
                .padding(.leading, protectedLeadingSpace)
                .padding(.trailing, contentInset)
                .padding(.vertical, contentInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            }
        }
        .clipShape(.rect(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Now Playing Sound Lab")
        .accessibilityIdentifier("Now Playing Sound Lab")
    }

    private var panelGradient: LinearGradient {
        LinearGradient(
            colors: [
                .mint.opacity(0.20),
                .yellow.opacity(0.16),
                .pink.opacity(0.14),
                .cyan.opacity(0.16)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
