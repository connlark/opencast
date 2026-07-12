import SwiftUI

struct NowPlayingPeelAdFreePassControl: View {
    let presentation: EpisodeAdFreePassPresentation
    let onPrimaryAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button(action: onPrimaryAction) {
                HStack(spacing: 7) {
                    Image(systemName: "megaphone")
                        .font(.subheadline)
                        .frame(width: 24, height: 24)
                        .foregroundStyle(.white)
                        .background {
                            Circle()
                                .fill(buttonTint)
                                .animation(.easeOut(duration: 0.2), value: buttonTint)
                        }

                    Text(presentation.primaryActionTitle)
                        .font(.footnote)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)

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
            .disabled(!presentation.isPrimaryActionEnabled)
            .opacity(presentation.isPrimaryActionEnabled ? 1 : 0.62)
            .animation(
                .easeOut(duration: 0.2),
                value: presentation.isPrimaryActionEnabled
            )
            .accessibilityLabel(presentation.primaryActionTitle)
            .accessibilityValue(presentation.statusText)
            .accessibilityIdentifier("Skip Promos & Ads")

            Text(presentation.statusText)
                .font(.footnote)
                .foregroundStyle(statusStyle)
                .lineLimit(2)
                .minimumScaleFactor(0.74)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var buttonTint: Color {
        switch presentation.stage {
        case .failed:
            .orange
        case .completed:
            .green
        case .unavailable:
            .gray
        default:
            .red
        }
    }

    private var statusStyle: AnyShapeStyle {
        switch presentation.stage {
        case .failed:
            AnyShapeStyle(.orange)
        case .completed:
            AnyShapeStyle(.green)
        default:
            AnyShapeStyle(.secondary)
        }
    }

    private var trailingSystemImage: String {
        switch presentation.stage {
        case .downloadingEpisode, .installingModel, .transcribing, .analyzing:
            "hourglass"
        case .completed:
            "checkmark.circle.fill"
        case .failed, .interrupted:
            "arrow.clockwise"
        default:
            "chevron.right"
        }
    }
}
