import OpenCastCore
import SwiftUI

struct OnboardingPodcastSearchSection: View {
    @Bindable var store: PodcastSearchStore
    let focusedField: FocusState<OnboardingFocusedField?>.Binding
    let activePodcastIDs: Set<String>
    let subscribingFeedURLString: String?
    let onSubscribe: (DirectoryPodcastResult) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Search")
                .font(.headline)
                .foregroundStyle(.secondary)

            TextField("Podcast or creator", text: $store.query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused(focusedField, equals: .podcastSearch)
                .onSubmit(hideKeyboard)
                .padding(.horizontal, 18)
                .frame(minHeight: 56)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 30))

            searchStateContent
        }
        .onDisappear {
            store.cancelSearch()
        }
    }

    @ViewBuilder
    private var searchStateContent: some View {
        switch store.state {
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
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
        case .empty:
            ContentUnavailableView(
                "No Results",
                systemImage: "magnifyingglass",
                description: Text("Try another search.")
            )
            .padding(14)
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
        case .results(let results):
            VStack(spacing: 0) {
                ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                    Button {
                        subscribe(to: result)
                    } label: {
                        PodcastSearchResultRow(
                            result: result,
                            isSubscribed: isSubscribed(result),
                            isSubscribing: isSubscribingResult(result)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isSubscribeDisabled(for: result))
                    .accessibilityHint(accessibilityHint(for: result))

                    if index < results.count - 1 {
                        Divider()
                            .padding(.leading, 64)
                    }
                }
            }
            .padding(14)
            .glassEffect(.regular, in: .rect(cornerRadius: 24))
        }
    }

    private var isSubscribing: Bool {
        subscribingFeedURLString != nil
    }

    private func hideKeyboard() {
        focusedField.wrappedValue = nil
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

    private func isSubscribed(_ result: DirectoryPodcastResult) -> Bool {
        guard let feedURLString = result.feedURLString else {
            return false
        }

        let canonicalFeedURLString = URLCanonicalizer.canonicalString(forRawString: feedURLString)
        return activePodcastIDs.contains(canonicalFeedURLString)
    }

    private func isSubscribeDisabled(for result: DirectoryPodcastResult) -> Bool {
        isSubscribing || result.feedURLString == nil || isSubscribed(result)
    }

    private func accessibilityHint(for result: DirectoryPodcastResult) -> String {
        if result.feedURLString == nil {
            return "This podcast cannot be subscribed because the directory did not provide an RSS feed."
        }

        if isSubscribed(result) {
            return "This podcast is already in your library."
        }

        return "Subscribes to this podcast."
    }
}
