import SwiftUI

/// Shared chrome for tappable Sound Lab rows: leading tinted icon, title
/// (dropped when collapsed to icon-only), and a trailing state glyph. The
/// full title always remains the accessibility label.
struct NowPlayingSoundLabActionRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var acceptedFeedback = 0

    let title: String
    let systemImage: String
    let tint: Color
    let phase: EpisodeAdFreePassPresentationPhase
    let isEnabled: Bool
    let isIconOnly: Bool
    /// Nil fits the row to its label, which then wraps instead of truncating.
    let rowHeight: CGFloat?
    let accessibilityValueText: String
    let accessibilityID: String
    /// Whether the styled capsule, and with it the tap target, is `rowHeight`
    /// tall; otherwise the style's chrome stands outside the row.
    var capsuleFitsRow = false
    let action: () -> Void

    var body: some View {
        Button(action: performAction) {
            labelContent(reduceMotion: reduceMotion)
                .frame(maxWidth: .infinity, minHeight: labelMinimumHeight)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .frame(height: rowHeight)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.62)
        .animation(.easeOut(duration: 0.2), value: isEnabled)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityValueText)
        .accessibilityIdentifier(accessibilityID)
        .accessibilityShowsLargeContentViewer {
            Label(title, systemImage: systemImage)
        }
        .sensoryFeedback(.selection, trigger: acceptedFeedback)
        .onChange(of: phase, initial: true, renderPhaseChanged)
    }

    /// Everything inside the capsule; the row sets its height.
    func labelContent(reduceMotion: Bool) -> some View {
        HStack(spacing: NowPlayingSoundLabLayout.controlSpacing) {
            NowPlayingSoundLabControlIcon(
                systemImage: systemImage,
                tint: tint
            )

            if !isIconOnly {
                Text(title)
                    .font(.subheadline)
                    .lineLimit(rowHeight == nil ? nil : 1)
                    .layoutPriority(1)
                    .contentTransition(.opacity)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: title)
            }

            Spacer(minLength: showsTrailingIndicator ? NowPlayingSoundLabLayout.trailingIndicatorMinimumGap : 0)

            if showsTrailingIndicator {
                NowPlayingSoundLabTrailingIndicator(
                    phase: phase,
                    tint: tint
                )
            }
        }
        .padding(.horizontal, NowPlayingSoundLabLayout.controlHorizontalPadding)
    }

    private var labelMinimumHeight: CGFloat {
        guard capsuleFitsRow, let rowHeight else {
            return NowPlayingSoundLabLayout.minimumHitTarget
        }
        return rowHeight - 2 * NowPlayingSoundLabLayout.nativeGlassButtonVerticalChrome
    }

    private var showsTrailingIndicator: Bool {
        phase != .idle && phase != .unavailable
    }

    private func performAction() {
        guard isEnabled else {
            return
        }

        acceptedFeedback += 1
        SoundLabResponsivenessDiagnostics.mark(
            "action-entry-\(accessibilityID)"
        )
        nowPlayingProbeMark("sound-lab-action-entry")
        action()
    }

    private func renderPhaseChanged(
        _ oldPhase: EpisodeAdFreePassPresentationPhase,
        _ newPhase: EpisodeAdFreePassPresentationPhase
    ) {
        guard oldPhase != newPhase || newPhase != .idle else {
            return
        }

        SoundLabResponsivenessDiagnostics.mark(
            "rendered-phase-\(newPhase)",
            episodeID: nil
        )
        nowPlayingProbeMark("sound-lab-rendered-\(newPhase)")
    }
}
