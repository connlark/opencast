import OpenCastCore
import SwiftUI

struct OnboardingPodcastResultList: View {
    let results: [DirectoryPodcastResult]
    let addFlow: DirectorySubscriptionFlowStore
    let knownPodcasts: KnownPodcastsStore
    let activePodcastIDs: Set<String>
    let onOpen: (DirectoryPodcastResult) -> Void
    let onAdd: (DirectoryPodcastResult) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(results) { result in
                let status = PodcastResultRow.Status(
                    of: result,
                    addFlow: addFlow,
                    knownPodcasts: knownPodcasts,
                    activePodcastIDs: activePodcastIDs
                )
                PodcastResultRow(
                    result: result,
                    status: status,
                    openHint: status.openHint(opensShowPage: false),
                    onOpen: { onOpen(result) },
                    onAdd: { onAdd(result) }
                )
                .padding(.vertical, 6)
                .disabled(addFlow.isBusy && status != .adding)

                if result.id != results.last?.id {
                    Divider()
                        .padding(.leading, 64)
                }
            }
        }
    }
}
