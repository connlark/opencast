import SwiftUI

struct PodcastDetailView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var isConfirmingUnsubscribe = false
    @State private var isConfirmingAdAutoDetect = false
    @State private var searchQuery = ""
    @State private var searchMode: EpisodeSearchMode = .episodes
    @State private var searchSession = EpisodeSearchSession()

    let feedURL: String
    var onOpenEpisode: (String) -> Void = { _ in }

    private var subscription: SubscriptionRecord? {
        appModel.library.subscriptions.first { $0.feedURL == feedURL }
    }

    private var podcastCache: PodcastCacheSnapshot? {
        appModel.library.podcastCache(for: feedURL)
    }

    private var episodes: [EpisodeListItemSnapshot] {
        appModel.library.episodes(forPodcastID: feedURL)
    }

    private var hasSearchQuery: Bool {
        EpisodeSearch.isSearchActive(query: searchQuery)
    }

    private var searchPrompt: String {
        guard let subscription else {
            return "Search Podcast"
        }

        return "Search \(subscription.title)"
    }

    private var isRefreshing: Bool {
        appModel.library.isRefreshing(feedURL: feedURL)
    }

    private var latestRefreshLog: RefreshLogSnapshot? {
        appModel.library.latestRefreshLog(feedURL: feedURL)
    }

    private var refreshErrorMessage: String? {
        guard let errorMessage = latestRefreshLog?.errorMessage,
              !errorMessage.isEmpty
        else {
            return nil
        }

        return errorMessage
    }

    var body: some View {
        let podcastEpisodes = episodes
        let episodeIDs = podcastEpisodes.map(\.episodeID)
        let searchTaskKey = EpisodeSearchRequestKey(
            episodes: podcastEpisodes,
            query: searchQuery,
            mode: searchMode
        )
        let searchResults = searchSession.displayedResults(for: searchTaskKey)

        Group {
            if let subscription {
                List {
                    Section {
                        HStack(spacing: 14) {
                            ArtworkPlaceholder(
                                title: subscription.title,
                                imageURL: podcastCache?.artworkURL ?? subscription.artworkURL,
                                size: 76,
                                preview: podcastCache?.artworkPreview,
                                onPreviewResolved: updatePodcastArtworkPreview
                            )
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 8) {
                                    Text(subscription.title)
                                        .font(.title2)
                                        .fixedSize(horizontal: false, vertical: true)
                                    if isRefreshing {
                                        ProgressView()
                                            .controlSize(.small)
                                            .accessibilityLabel("Refreshing")
                                    }
                                }
                                if let author = subscription.author {
                                    Text(author)
                                        .foregroundStyle(.secondary)
                                }
                                if let lastRefreshAt = subscription.lastRefreshAt {
                                    Text("Refreshed \(lastRefreshAt.formatted(.relative(presentation: .named)))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if let refreshErrorMessage {
                                    Label(refreshErrorMessage, systemImage: "exclamationmark.triangle.fill")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                        .lineLimit(2)
                                }
                            }
                        }
                        .padding(.vertical, 8)
                    }

                    Section("Episodes") {
                        if podcastEpisodes.isEmpty {
                            ContentUnavailableView("No Episodes", systemImage: "waveform")
                        } else if hasSearchQuery {
                            EpisodeSearchResultsContent(
                                mode: searchMode,
                                isLoadingVisible: searchSession.isLoadingVisible,
                                isSearching: searchSession.isSearching,
                                results: searchResults,
                                fallbackEpisodes: podcastEpisodes
                            ) { episode, result in
                                EpisodeRowButton(
                                    episode: episode,
                                    searchResult: result,
                                    onSelect: dismissSearchKeyboard,
                                    onOpenEpisode: onOpenEpisode
                                )
                            }
                        } else {
                            ForEach(podcastEpisodes) { episode in
                                EpisodeRowButton(
                                    episode: episode,
                                    onSelect: dismissSearchKeyboard,
                                    onOpenEpisode: onOpenEpisode
                                )
                            }
                        }
                    }
                }
                .scrollDismissesKeyboard(.immediately)
                .contentMargins(.bottom, 72, for: .scrollContent)
                .animation(listAnimation, value: episodeIDs)
                .animation(listAnimation, value: appModel.library.state)
            } else {
                ContentUnavailableView(
                    "Podcast Not Found",
                    systemImage: "questionmark.circle",
                    description: Text("This subscription is no longer in your library.")
                )
            }
        }
        .navigationTitle(subscription?.title ?? "Podcast")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchQuery, prompt: searchPrompt)
        .searchScopes($searchMode) {
            EpisodeSearchScopePicker()
        }
        .task(id: searchTaskKey) {
            let library = appModel.library
            let podcastID = feedURL
            await searchSession.update(
                episodes: podcastEpisodes,
                query: searchQuery,
                mode: searchMode,
                showNotesProvider: { await library.showNotesHTMLByEpisodeID(forPodcastID: podcastID) }
            )
        }
        .toolbar {
            if subscription != nil {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Refresh", systemImage: "arrow.clockwise") {
                            Task {
                                await appModel.library.refresh(feedURL: feedURL, modelContext: modelContext)
                            }
                        }
                        .disabled(isRefreshing)

                        Toggle(
                            "Automatically Detect Ads",
                            systemImage: "megaphone",
                            isOn: adAutoDetectBinding
                        )

                        Button("Unsubscribe", systemImage: "trash", role: .destructive) {
                            isConfirmingUnsubscribe = true
                        }
                    } label: {
                        Label("Podcast Actions", systemImage: "ellipsis.circle")
                    }
                }
            }
        }
        .confirmationDialog(
            "Unsubscribe from \(subscription?.title ?? "this podcast")?",
            isPresented: $isConfirmingUnsubscribe,
            titleVisibility: .visible
        ) {
            Button("Unsubscribe", role: .destructive) {
                unsubscribe()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Cached episodes, progress, refresh logs, and local downloads for this podcast will be removed.")
        }
        .confirmationDialog(
            "Automatically detect ads?",
            isPresented: $isConfirmingAdAutoDetect,
            titleVisibility: .visible
        ) {
            Button("Turn On") {
                setAdAutoDetectEnabled(true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Episodes of this show will be analyzed for ads when you play them.")
        }
    }

    private var listAnimation: Animation? {
        hasSearchQuery || reduceMotion ? nil : .default
    }

    private var adAutoDetectBinding: Binding<Bool> {
        Binding(
            get: { subscription?.isAdAutoDetectEnabled ?? false },
            set: { isEnabled in
                if isEnabled {
                    // Enabling is a standing opt-in — confirm first.
                    isConfirmingAdAutoDetect = true
                } else {
                    setAdAutoDetectEnabled(false)
                }
            }
        )
    }

    private func setAdAutoDetectEnabled(_ isEnabled: Bool) {
        appModel.library.setAdAutoDetectEnabled(
            isEnabled,
            feedURL: feedURL,
            modelContext: modelContext
        )
    }

    private func unsubscribe() {
        Task {
            await appModel.unsubscribe(feedURL: feedURL, modelContext: modelContext)
            dismiss()
        }
    }

    private func updatePodcastArtworkPreview(_ preview: ArtworkPreview) {
        guard let podcastCache else {
            return
        }

        appModel.library.updateArtworkPreview(preview, for: podcastCache)
    }

    private func dismissSearchKeyboard() {
        KeyboardDismissal.dismiss()
    }
}
