import SwiftUI

struct PodcastDetailView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var isConfirmingUnsubscribe = false
    @State private var searchQuery = ""
    @State private var searchMode: EpisodeSearchMode = .episodes
    @State private var searchSession = EpisodeSearchSession()

    let feedURL: String
    var onUnsubscribe: () -> Void = {}
    var onOpenEpisode: (String) -> Void = { _ in }
    var selectsEpisodeDetailOnPlay = false

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
        let searchTaskKey = EpisodeSearchRequestKey(
            episodes: podcastEpisodes,
            query: searchQuery,
            mode: searchMode
        )

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
                            if searchSession.isSearching {
                                ProgressView("Searching")
                            } else if searchSession.results.isEmpty {
                                ContentUnavailableView.search
                            } else {
                                ForEach(searchSession.results) { result in
                                    EpisodeRowButton(
                                        episode: result.episode,
                                        searchResult: result,
                                        selectsEpisodeDetailOnPlay: selectsEpisodeDetailOnPlay,
                                        onOpenEpisode: onOpenEpisode
                                    )
                                }
                            }
                        } else {
                            ForEach(podcastEpisodes) { episode in
                                EpisodeRowButton(
                                    episode: episode,
                                    selectsEpisodeDetailOnPlay: selectsEpisodeDetailOnPlay,
                                    onOpenEpisode: onOpenEpisode
                                )
                            }
                        }
                    }
                }
                .contentMargins(.bottom, 72, for: .scrollContent)
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
    }

    private func unsubscribe() {
        Task {
            await appModel.unsubscribe(feedURL: feedURL, modelContext: modelContext)
            onUnsubscribe()
            dismiss()
        }
    }

    private func updatePodcastArtworkPreview(_ preview: ArtworkPreview) {
        guard let podcastCache else {
            return
        }

        appModel.library.updateArtworkPreview(preview, for: podcastCache)
    }
}
