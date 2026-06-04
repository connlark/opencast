import OpenCastCore
import SwiftUI

struct PodcastSearchView: View {
    @Bindable var store: PodcastSearchStore
    let subscribingFeedURLString: String?
    let onSubscribe: (DirectoryPodcastResult) -> Void

    @FocusState private var isSearchFocused: Bool

    var body: some View {
        Group {
            Section("Search") {
                TextField("Podcast or creator", text: $store.query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($isSearchFocused)
                    .onSubmit(hideKeyboard)
            }

            switch store.state {
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
                            subscribe(to: result)
                        } label: {
                            PodcastSearchResultRow(
                                result: result,
                                isSubscribing: isSubscribingResult(result)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(isSubscribing || result.feedURLString == nil)
                        .accessibilityHint(accessibilityHint(for: result))
                    }
                }
            }
        }
        .onDisappear {
            store.cancelSearch()
        }
    }

    private var isSubscribing: Bool {
        subscribingFeedURLString != nil
    }

    private func hideKeyboard() {
        isSearchFocused = false
    }

    private func subscribe(to result: DirectoryPodcastResult) {
        hideKeyboard()
        onSubscribe(result)
    }

    private func isSubscribingResult(_ result: DirectoryPodcastResult) -> Bool {
        guard let feedURLString = result.feedURLString else {
            return false
        }

        return feedURLString == subscribingFeedURLString
    }

    private func accessibilityHint(for result: DirectoryPodcastResult) -> String {
        if result.feedURLString == nil {
            return "This podcast cannot be subscribed because the directory did not provide an RSS feed."
        }

        return "Subscribes to this podcast."
    }
}
