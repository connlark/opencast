import OpenCastCore
import SwiftUI

struct OnboardingPodcastSetupPage: View {
    @Bindable var searchStore: PodcastSearchStore

    let addFlow: DirectorySubscriptionFlowStore
    let knownPodcasts: KnownPodcastsStore
    let subscriptions: [SubscriptionRecord]
    let activePodcastIDs: Set<String>
    let isSearchFieldFocused: FocusState<Bool>.Binding
    let onOpenResult: (DirectoryPodcastResult) -> Void
    let onOpenFeed: (URL) -> Void
    let onQuickAdd: (DirectoryPodcastResult) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Find Podcasts")
                    .font(.largeTitle)
                    .bold()

                OnboardingPodcastSearchField(text: $searchStore.query, isFocused: isSearchFieldFocused)

                if let failure = addFlow.failure {
                    PodcastAddFailureRow(failure: failure, onDismiss: addFlow.clearError)
                }

                if searchStore.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if showsSuggestions {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Suggested Shows")
                                .font(.headline)
                                .accessibilityAddTraits(.isHeader)

                            resultList(OpenCastSamplePodcastSuggestions.all)
                        }
                    } else {
                        OnboardingSubscribedPodcastsSection(subscriptions: subscriptions)
                    }
                } else {
                    if let feedURL = PodcastFeedURLDetector.openableFeedURL(from: searchStore.query) {
                        PodcastOpenFeedRow(feedURL: feedURL) {
                            onOpenFeed(feedURL)
                        }
                        .disabled(addFlow.isBusy)
                    }

                    searchContent
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollIndicators(.hidden)
        .scrollContentBackground(.visible)
    }

    private var showsSuggestions: Bool {
        let suggestionFeedURLs = OpenCastSamplePodcastSuggestions.all.reduce(into: Set<String>()) { urls, suggestion in
            urls.formUnion(knownPodcasts.feedURLs(for: suggestion.knownPodcastKey))
        }
        return activePodcastIDs.isSubset(of: suggestionFeedURLs)
    }

    @ViewBuilder
    private var searchContent: some View {
        switch searchStore.state {
        case .idle:
            EmptyView()
        case .error(let errorMessage):
            Label(errorMessage, systemImage: "exclamationmark.triangle")
                .font(.subheadline)
                .foregroundStyle(.red)
        case .loading:
            HStack(spacing: 10) {
                ProgressView()
                Text("Searching")
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
        case .empty:
            ContentUnavailableView(
                "No Results",
                systemImage: "magnifyingglass",
                description: Text("Try another search.")
            )
        case .results(let results):
            VStack(alignment: .leading, spacing: 8) {
                resultList(results)
                PodcastIndexAttributionFooter(results: results)
            }
        }
    }

    private func resultList(_ results: [DirectoryPodcastResult]) -> OnboardingPodcastResultList {
        OnboardingPodcastResultList(
            results: results,
            addFlow: addFlow,
            knownPodcasts: knownPodcasts,
            activePodcastIDs: activePodcastIDs,
            onOpen: onOpenResult,
            onAdd: onQuickAdd
        )
    }
}
