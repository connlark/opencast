import SwiftUI

/// Glass progress card observing the ad-free pipeline. Rendered only while
/// work runs or a step failed; `EpisodePipelineState.make` decides that.
struct EpisodePipelineCard: View {
    let state: EpisodePipelineState
    let onAction: (EpisodePipelineAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(state.title)
                    .font(.headline)

                Spacer(minLength: 12)

                if let action = state.action {
                    Button(action.title) {
                        onAction(action)
                    }
                    .font(.subheadline)
                    .buttonStyle(.glass)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(state.steps) { step in
                    EpisodePipelineStepRow(step: step)
                }
            }

            if let footnote = state.footnote {
                Text(footnote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
    }
}

#Preview("Dark") {
    VStack(spacing: 16) {
        EpisodePipelineCard(
            state: EpisodePipelineState(
                title: EpisodePipelineState.passTitle,
                steps: [
                    EpisodePipelineStep(kind: .download, status: .done),
                    EpisodePipelineStep(
                        kind: .transcribe,
                        status: .running(fraction: 0.58, detail: "34:00 of 58:00")
                    ),
                    EpisodePipelineStep(kind: .detectAds, status: .waiting)
                ],
                footnote: nil,
                action: .cancelPass
            ),
            onAction: { _ in }
        )
        EpisodePipelineCard(
            state: EpisodePipelineState(
                title: EpisodePipelineState.downloadFailedTitle,
                steps: [
                    EpisodePipelineStep(
                        kind: .download,
                        status: .failed(message: EpisodePipelineState.downloadFailedMessage)
                    )
                ],
                footnote: nil,
                action: .retryDownload
            ),
            onAction: { _ in }
        )
    }
    .padding()
    .preferredColorScheme(.dark)
}

#Preview("Light") {
    EpisodePipelineCard(
        state: EpisodePipelineState(
            title: EpisodePipelineState.passTitle,
            steps: [
                EpisodePipelineStep(kind: .download, status: .done),
                EpisodePipelineStep(kind: .transcribe, status: .done),
                EpisodePipelineStep(kind: .detectAds, status: .running(fraction: nil, detail: nil))
            ],
            footnote: "Queued — 2 ahead",
            action: .removeFromQueue
        ),
        onAction: { _ in }
    )
    .padding()
    .preferredColorScheme(.light)
}
