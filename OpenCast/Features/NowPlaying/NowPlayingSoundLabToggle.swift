import SwiftUI

struct NowPlayingSoundLabToggle: View {
    let title: String
    let systemImage: String
    let tint: Color
    let isEnabled: Bool
    let isIconOnly: Bool
    let rowHeight: CGFloat
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: NowPlayingSoundLabLayout.controlSpacing) {
                NowPlayingSoundLabControlIcon(
                    systemImage: systemImage,
                    tint: tint
                )

                Text(title)
                    .font(.subheadline)
                    .lineLimit(1)
                    .layoutPriority(1)
                    .frame(width: isIconOnly ? 0 : nil)
                    .opacity(isIconOnly ? 0 : 1)
                    .clipped()
            }
        }
        .toggleStyle(.switch)
        .tint(tint)
        .padding(
            .leading,
            NowPlayingSoundLabLayout.controlHorizontalPadding
                + NowPlayingSoundLabLayout.nativeGlassButtonLeadingInset
        )
        .padding(.trailing, NowPlayingSoundLabLayout.controlHorizontalPadding)
        .frame(
            maxWidth: .infinity,
            minHeight: 44
        )
        .frame(height: rowHeight)
        .contentShape(.capsule)
        .glassEffect(.regular.interactive(), in: .capsule)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.62)
        .animation(.easeOut(duration: 0.16), value: isEnabled)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityHint(isEnabled ? "" : "Controlled by the global Voice Boost setting")
        .accessibilityIdentifier(title)
        .accessibilityShowsLargeContentViewer {
            Label(title, systemImage: systemImage)
        }
        .sensoryFeedback(.selection, trigger: isOn)
    }
}
