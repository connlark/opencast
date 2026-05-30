import OpenCastCore
import SwiftUI

struct OnboardingPopularPodcastsPage: View {
    @Bindable var store: PopularPodcastsStore
    let activePodcastIDs: Set<String>
    let subscribingFeedURLString: String?
    let subscriptionErrorMessage: String?
    let onSubscribe: (DirectoryPodcastResult) -> Void

    var body: some View {
        Form {
            Section {
                Text("Start with a few popular shows, or finish setup and add your own later.")
                    .foregroundStyle(.secondary)
            } header: {
                Text("Popular Podcasts")
            }

            switch store.state {
            case .idle:
                EmptyView()
            case .loading:
                Section {
                    HStack {
                        ProgressView()
                        Text("Loading suggestions")
                            .foregroundStyle(.secondary)
                    }
                }
            case .empty:
                Section {
                    ContentUnavailableView(
                        "No Suggestions",
                        systemImage: "sparkles.rectangle.stack",
                        description: Text("You can add podcasts from Library after setup.")
                    )
                }
            case .failed(let message):
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            case .loaded(let results):
                Section("Suggestions") {
                    ForEach(results) { result in
                        PopularPodcastSuggestionRow(
                            result: result,
                            isSubscribed: isSubscribed(result),
                            isSubscribing: isSubscribing(result),
                            isDisabled: isSubscribeDisabled(for: result),
                            onSubscribe: { onSubscribe(result) }
                        )
                    }
                }
            }

            if let subscriptionErrorMessage {
                Section {
                    Label(subscriptionErrorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        }
        .task {
            await store.loadPopularIfNeeded()
        }
    }

    private func isSubscribed(_ result: DirectoryPodcastResult) -> Bool {
        guard let feedURLString = result.feedURLString else {
            return false
        }

        return activePodcastIDs.contains(feedURLString)
    }

    private func isSubscribing(_ result: DirectoryPodcastResult) -> Bool {
        guard let feedURLString = result.feedURLString else {
            return false
        }

        return subscribingFeedURLString == feedURLString
    }

    private func isSubscribeDisabled(for result: DirectoryPodcastResult) -> Bool {
        subscribingFeedURLString != nil || result.feedURLString == nil || isSubscribed(result)
    }
}
