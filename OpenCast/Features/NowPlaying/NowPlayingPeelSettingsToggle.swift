import SwiftUI

struct NowPlayingPeelSettingsToggle: View {
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    let title: String
    let systemImage: String
    let tint: Color
    let isEnabled: Bool
    @Binding var isOn: Bool

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.subheadline)
                    .frame(width: 24, height: 24)
                    .foregroundStyle(isOn ? .white : tint)
                    .background {
                        Circle()
                            .fill(isOn ? tint : tint.opacity(0.18))
                    }

                Text(title)
                    .font(.footnote)
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)

                Spacer(minLength: 4)

                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule()
                        .fill(isOn ? tint.opacity(0.82) : .primary.opacity(0.13))

                    Circle()
                        .fill(.white)
                        .overlay {
                            if differentiateWithoutColor, isOn {
                                Image(systemName: "checkmark")
                                    .font(.caption)
                                    .foregroundStyle(tint)
                            }
                        }
                        .padding(2)
                        .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                }
                .frame(width: 36, height: 21)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, minHeight: 38)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.62)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityHint(isEnabled ? "" : "Controlled by the global Voice Boost setting")
        .accessibilityIdentifier(title)
        .sensoryFeedback(.selection, trigger: isOn)
    }

    private func toggle() {
        withAnimation(.bouncy) {
            isOn.toggle()
        }
    }
}
