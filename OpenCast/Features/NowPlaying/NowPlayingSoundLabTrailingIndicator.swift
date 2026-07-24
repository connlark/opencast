import SwiftUI

struct NowPlayingSoundLabTrailingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let phase: EpisodeAdFreePassPresentationPhase
    let tint: Color

    var body: some View {
        Group {
            switch phase {
            case .queued, .checking, .running:
                ProgressView()
                    .controlSize(.small)
                    .tint(tint)
            case .completed:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(tint)
            case .failed:
                Image(systemName: "arrow.clockwise")
                    .foregroundStyle(tint)
            case .deferred:
                Image(systemName: "clock.badge.exclamationmark")
                    .foregroundStyle(tint)
            case .idle, .unavailable:
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.subheadline)
        .frame(
            width: NowPlayingSoundLabLayout.trailingIndicatorSize,
            height: NowPlayingSoundLabLayout.trailingIndicatorSize
        )
        .contentTransition(.interpolate)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: phase)
        .accessibilityHidden(true)
    }
}
