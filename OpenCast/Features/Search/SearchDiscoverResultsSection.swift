import OpenCastCore
import SwiftUI

struct SearchDiscoverResultsSection: View {
    @Bindable var searchStore: PodcastSearchStore
    let activePodcastIDs: Set<String>
    let subscribingResultID: String?
    let isSubscriptionInProgress: Bool
    let onSubscribe: (DirectoryPodcastResult) -> Void
    let onOpenPodcast: (String) -> Void

    var body: some View {
        switch searchStore.state {
        case .idle:
            EmptyView()
        case .error(let errorMessage):
            Section {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
        case .loading:
            Section {
                HStack {
                    ProgressView()
                    Text("Searching")
                        .foregroundStyle(.secondary)
                }
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
                    Button {
                        select(result)
                    } label: {
                        PodcastSearchResultRow(
                            result: result,
                            isSubscribed: isSubscribed(result),
                            isSubscribing: result.id == subscribingResultID
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isSelectionDisabled(result))
                    .accessibilityHint(accessibilityHint(result))
                }
            } header: {
                Text("Results")
            } footer: {
                PodcastIndexAttributionFooter(results: results)
            }
        }
    }

    private func select(_ result: DirectoryPodcastResult) {
        // The active subscription may live under any candidate URL of a
        // merged result, not just the display feed URL.
        if let subscribedPodcastID = subscribedPodcastID(result) {
            onOpenPodcast(subscribedPodcastID)
            return
        }
        guard result.canResolveFeed else {
            return
        }

        onSubscribe(result)
    }

    private func subscribedPodcastID(_ result: DirectoryPodcastResult) -> String? {
        result.candidateCanonicalFeedURLStrings.first(where: activePodcastIDs.contains)
    }

    private func isSubscribed(_ result: DirectoryPodcastResult) -> Bool {
        result.isSubscribed(activePodcastIDs: activePodcastIDs)
    }

    private func isSelectionDisabled(_ result: DirectoryPodcastResult) -> Bool {
        isSubscriptionInProgress || !result.canResolveFeed
    }

    private func accessibilityHint(_ result: DirectoryPodcastResult) -> String {
        if !result.canResolveFeed {
            return "This podcast cannot be opened because the directory did not provide an RSS feed."
        }

        if isSubscribed(result) {
            return "Opens this podcast in your library."
        }

        return "Subscribes to this podcast."
    }
}
