import SwiftUI

/// Shared chrome for tappable Sound Lab rows: leading tinted icon, title
/// (dropped when collapsed to icon-only), and a trailing state glyph. The
/// full title always remains the accessibility label.
struct NowPlayingPeelActionRow: View {
    let title: String
    let systemImage: String
    let tint: Color
    let trailingSystemImage: String
    let isEnabled: Bool
    let isIconOnly: Bool
    let accessibilityValueText: String
    let accessibilityID: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.subheadline)
                    .frame(width: 24, height: 24)
                    .foregroundStyle(.white)
                    .background {
                        Circle()
                            .fill(tint)
                            .animation(.easeOut(duration: 0.2), value: tint)
                    }

                if !isIconOnly {
                    Text(title)
                        .font(.footnote)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }

                Spacer(minLength: 4)

                Image(systemName: trailingSystemImage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .contentTransition(.symbolEffect(.replace))
                    .animation(.easeOut(duration: 0.2), value: trailingSystemImage)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, minHeight: 38)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.62)
        .animation(.easeOut(duration: 0.2), value: isEnabled)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityValueText)
        .accessibilityIdentifier(accessibilityID)
        .accessibilityShowsLargeContentViewer {
            Label(title, systemImage: systemImage)
        }
    }
}
