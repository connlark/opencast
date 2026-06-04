import OpenCastCore
import SwiftData
import SwiftUI

struct AddPodcastView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var feedURLString: String
    @State private var selectedMode = AddPodcastMode.rss
    @State private var searchStore: PodcastSearchStore
    @State private var subscriptionErrorMessage: String?
    @State private var subscribingFeedURLString: String?
    @State private var clipboardErrorMessage: String?
    @State private var hasRequestedClipboardOnOpen = false

    init(
        initialFeedURL: String = OpenCastConstants.addPodcastInitialFeedURL,
        directoryService: any PodcastDirectoryService = ITunesPodcastDirectoryService()
    ) {
        _feedURLString = State(initialValue: initialFeedURL)
        _searchStore = State(initialValue: PodcastSearchStore(directoryService: directoryService))
    }

    var body: some View {
        NavigationStack {
            Group {
                switch selectedMode {
                case .rss:
                    AddPodcastRSSView(
                        selectedMode: $selectedMode,
                        feedURLString: $feedURLString,
                        subscriptionErrorMessage: subscriptionErrorMessage,
                        clipboardErrorMessage: clipboardErrorMessage,
                        isSubscribing: isSubscribing,
                        canSubscribe: canSubscribeToRawFeed,
                        onPaste: pasteFromClipboard,
                        onSubmit: subscribeToRawFeed
                    )
                case .search:
                    Form {
                        AddPodcastModePicker(selectedMode: $selectedMode)

                        PodcastSearchView(
                            store: searchStore,
                            subscribingFeedURLString: subscribingFeedURLString,
                            onSubscribe: subscribeToSearchResult
                        )

                        if let subscriptionErrorMessage {
                            Section {
                                Label(subscriptionErrorMessage, systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                }
            }
            .navigationTitle(selectedMode == .search ? "Add Podcast" : "")
            .navigationBarTitleDisplayMode(selectedMode == .search ? .large : .inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if selectedMode == .rss {
                        if isSubscribing {
                            ProgressView()
                                .accessibilityLabel("Subscribing")
                        } else {
                            Button("Subscribe", systemImage: "plus", action: subscribeToRawFeed)
                                .disabled(!canSubscribeToRawFeed)
                        }
                    }
                }
            }
        }
        .task {
            requestClipboardURLOnOpen()
        }
        .onDisappear(perform: searchStore.cancelSearch)
    }

    private var canSubscribeToRawFeed: Bool {
        hasFeedURLText
    }

    private var isSubscribing: Bool {
        subscribingFeedURLString != nil
    }

    private var hasFeedURLText: Bool {
        !trimmedFeedURLString.isEmpty
    }

    private var trimmedFeedURLString: String {
        feedURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func subscribeToRawFeed() {
        guard canSubscribeToRawFeed, !isSubscribing else {
            return
        }

        startSubscription(to: feedURLString)
    }

    private func requestClipboardURLOnOpen() {
        guard !hasRequestedClipboardOnOpen else {
            return
        }
        hasRequestedClipboardOnOpen = true
        guard !hasFeedURLText else {
            return
        }

        pasteFromClipboard(replacesExistingText: false, reportsInvalidURL: false)
    }

    private func pasteFromClipboard() {
        pasteFromClipboard(replacesExistingText: true, reportsInvalidURL: true)
    }

    private func pasteFromClipboard(
        replacesExistingText: Bool,
        reportsInvalidURL: Bool
    ) {
        guard let copiedFeedURLString = AddPodcastClipboardReader.feedURLStringFromClipboard() else {
            if reportsInvalidURL {
                clipboardErrorMessage = "Clipboard does not contain an HTTP podcast feed URL."
            }
            return
        }

        guard replacesExistingText || !hasFeedURLText else {
            return
        }

        feedURLString = copiedFeedURLString
        clipboardErrorMessage = nil
    }

    private func subscribeToSearchResult(_ result: DirectoryPodcastResult) {
        guard let feedURLString = result.feedURLString else {
            return
        }

        startSubscription(to: feedURLString)
    }

    private func startSubscription(to feedURLString: String) {
        // Let the persistent subscribe operation finish if the sheet disappears.
        Task {
            await subscribe(to: feedURLString)
        }
    }

    private func subscribe(to feedURLString: String) async {
        subscriptionErrorMessage = nil
        clipboardErrorMessage = nil
        subscribingFeedURLString = feedURLString
        defer {
            subscribingFeedURLString = nil
        }

        do {
            try await appModel.library.subscribe(to: feedURLString, modelContext: modelContext)
            dismiss()
        } catch is CancellationError {
        } catch {
            subscriptionErrorMessage = error.localizedDescription
        }
    }
}
