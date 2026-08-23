import OpenCastCore
import SwiftUI

struct PodcastSearchView: View {
    @Bindable var store: PodcastSearchStore
    let isSubscriptionInProgress: Bool
    let subscribingResultID: String?
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
                Section {
                    ForEach(results) { result in
                        Button {
                            subscribe(to: result)
                        } label: {
                            PodcastSearchResultRow(
                                result: result,
                                isSubscribing: result.id == subscribingResultID
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(isSubscriptionInProgress || !result.canResolveFeed)
                        .accessibilityHint(accessibilityHint(for: result))
                    }
                } header: {
                    Text("Results")
                } footer: {
                    PodcastIndexAttributionFooter(results: results)
                }
            }
        }
        .onDisappear {
            store.cancelSearch()
        }
    }

    private func hideKeyboard() {
        isSearchFocused = false
    }

    private func subscribe(to result: DirectoryPodcastResult) {
        hideKeyboard()
        onSubscribe(result)
    }

    private func accessibilityHint(for result: DirectoryPodcastResult) -> String {
        if !result.canResolveFeed {
            return "This podcast cannot be subscribed because the directory did not provide an RSS feed."
        }

        return "Subscribes to this podcast."
    }
}
