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
    let rowHeight: CGFloat
    let accessibilityValueText: String
    let accessibilityID: String
    let action: () -> Void

    var body: some View {
        Button(action: performAction) {
            HStack(spacing: NowPlayingSoundLabLayout.controlSpacing) {
                NowPlayingSoundLabControlIcon(
                    systemImage: systemImage,
                    tint: tint
                )

                if !isIconOnly {
                    Text(title)
                        .font(.subheadline)
                        .lineLimit(1)
                        .layoutPriority(1)
                        .contentTransition(.opacity)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: title)
                }

                Spacer(minLength: showsTrailingIndicator ? 2 : 0)

                if showsTrailingIndicator {
                    NowPlayingSoundLabTrailingIndicator(
                        phase: phase,
                        tint: tint
                    )
                }
            }
            .padding(.horizontal, NowPlayingSoundLabLayout.controlHorizontalPadding)
            .frame(maxWidth: .infinity, minHeight: 44)
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
