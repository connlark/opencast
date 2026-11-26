import OpenCastCore
import SwiftUI

struct SearchDiscoverResultsSection: View {
    let searchStore: PodcastSearchStore
    let subscriptionFlow: DirectorySubscriptionFlowStore
    let knownPodcasts: KnownPodcastsStore
    let activePodcastIDs: Set<String>
    let onPreview: (DirectoryPodcastResult) -> Void
    let onQuickAdd: (DirectoryPodcastResult) -> Void
    let onOpenPodcast: (String) -> Void

    var body: some View {
        switch searchStore.state {
        case .idle:
            EmptyView()
        case .error(let errorMessage):
            Section {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                Button("Try Again", systemImage: "arrow.clockwise", action: searchStore.retrySearch)
            }
        case .loading:
            Section {
                ProgressView()
                    .accessibilityLabel("Searching")
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        case .empty:
            Section {
                ContentUnavailableView(
                    "No Results",
                    systemImage: "magnifyingglass",
                    description: Text("Try another search.")
                )
            }
        case .results(let results):
            Section {
                ForEach(results) { result in
                    let status = PodcastResultRow.Status(
                        of: result,
                        addFlow: subscriptionFlow,
                        knownPodcasts: knownPodcasts,
                        activePodcastIDs: activePodcastIDs
                    )
                    PodcastResultRow(
                        result: result,
                        status: status,
                        openHint: status.openHint(opensShowPage: true),
                        onOpen: { open(result) },
                        onAdd: { onQuickAdd(result) }
                    )
                    .disabled(subscriptionFlow.isBusy && status != .adding)
                }
            } footer: {
                PodcastIndexAttributionFooter(results: results)
            }
        }
    }

    private func open(_ result: DirectoryPodcastResult) {
        guard !subscriptionFlow.isBusy else {
            return
        }
        if let libraryFeedURL = knownPodcasts.libraryFeedURL(for: result.knownPodcastKey, activePodcastIDs: activePodcastIDs) {
            onOpenPodcast(libraryFeedURL)
            return
        }
        guard result.canResolveFeed else {
            return
        }

        onPreview(result)
    }
}
