import OpenCastCore
import SwiftUI

/// Presented when a directory result's candidate feeds materially
/// differ: both parsed catalogs are shown with provenance, and the
/// primary action follows the resolver's recommendation.
struct DirectoryFeedChoiceView: View {
    let pending: DirectorySubscriptionFlowStore.PendingChoice
    let onSelect: (ResolvedFeedCandidate) -> Void
    let onCancel: () -> Void

    var body: some View {
        let presentation = DirectoryFeedChoicePresentation(reason: pending.choice.reason)

        NavigationStack {
            ScrollView {
                GlassEffectContainer(spacing: 20) {
                    VStack(alignment: .leading, spacing: 20) {
                        DirectoryFeedChoiceExplanationCard(
                            title: presentation.explanationTitle,
                            systemImage: presentation.explanationSystemImage,
                            bodyText: presentation.explanationBody
                        )

                        DirectoryFeedCandidateOptionRow(
                            candidate: pending.choice.primary,
                            title: presentation.primaryTitle,
                            isRecommended: true,
                            actionTitle: "Subscribe",
                            onSubscribe: selectPrimary
                        )

                        DirectoryFeedCandidateOptionRow(
                            candidate: pending.choice.secondary,
                            title: presentation.secondaryTitle,
                            isRecommended: false,
                            actionTitle: presentation.secondaryActionTitle,
                            onSubscribe: selectSecondary
                        )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
            }
            .scrollContentBackground(.visible)
            .background(.background)
            .navigationTitle(pending.result.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
        .presentationSizing(.form)
        .presentationDragIndicator(.visible)
    }

    private func selectPrimary() {
        onSelect(pending.choice.primary)
    }

    private func selectSecondary() {
        onSelect(pending.choice.secondary)
    }
}

#Preview("Fuller feed promoted") {
    DirectoryFeedChoiceView(
        pending: DirectoryFeedChoicePreviewSamples.promoted,
        onSelect: { _ in },
        onCancel: {}
    )
}

#Preview("Stale archive") {
    DirectoryFeedChoiceView(
        pending: DirectoryFeedChoicePreviewSamples.stale,
        onSelect: { _ in },
        onCancel: {}
    )
}

#Preview("Partially read") {
    DirectoryFeedChoiceView(
        pending: DirectoryFeedChoicePreviewSamples.salvaged,
        onSelect: { _ in },
        onCancel: {}
    )
}
