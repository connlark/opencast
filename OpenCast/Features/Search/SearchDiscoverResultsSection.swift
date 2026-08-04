import OpenCastCore
import SwiftUI

struct SearchDiscoverResultsSection: View {
    @Bindable var searchStore: PodcastSearchStore
    let activePodcastIDs: Set<String>
    let subscribingFeedURLString: String?
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
            Section("Results") {
                ForEach(results) { result in
                    Button {
                        select(result)
                    } label: {
                        PodcastSearchResultRow(
                            result: result,
                            isSubscribed: isSubscribed(result),
                            isSubscribing: isSubscribing(result)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isSelectionDisabled(result))
                    .accessibilityHint(accessibilityHint(result))
                }
            }
        }
    }

    private var isSubscriptionInProgress: Bool {
        subscribingFeedURLString != nil
    }

    private func select(_ result: DirectoryPodcastResult) {
        guard let feedURLString = result.feedURLString else {
            return
        }

        if isSubscribed(result) {
            onOpenPodcast(URLCanonicalizer.canonicalString(forRawString: feedURLString))
        } else {
            onSubscribe(result)
        }
    }

    private func isSubscribed(_ result: DirectoryPodcastResult) -> Bool {
        result.isSubscribed(activePodcastIDs: activePodcastIDs)
    }

    private func isSubscribing(_ result: DirectoryPodcastResult) -> Bool {
        guard let feedURLString = result.feedURLString,
              let subscribingFeedURLString
        else {
            return false
        }

        return URLCanonicalizer.canonicalString(forRawString: feedURLString)
            == URLCanonicalizer.canonicalString(forRawString: subscribingFeedURLString)
    }

    private func isSelectionDisabled(_ result: DirectoryPodcastResult) -> Bool {
        isSubscriptionInProgress || result.feedURLString == nil
    }

    private func accessibilityHint(_ result: DirectoryPodcastResult) -> String {
        if result.feedURLString == nil {
            return "This podcast cannot be opened because the directory did not provide an RSS feed."
        }

        if isSubscribed(result) {
            return "Opens this podcast in your library."
        }

        return "Subscribes to this podcast."
    }
}
