import SwiftData
import SwiftUI

struct InboxView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.modelContext) private var modelContext
    @State private var visibleEpisodeCount = EpisodeCatalogContinuation.pageSize

    let onAdd: () -> Void
    let onOpenEpisode: (String) -> Void
    var onOpenAdDetectionQueue: () -> Void = {}

    private var groupedLayout: LibraryLayout {
        appModel.inboxEpisodeListSettings.groupedLayout.resolved(isRegularWidth: horizontalSizeClass == .regular)
    }

    var body: some View {
        let inboxEpisodes = appModel.library.inboxEpisodes
        let filter = appModel.inboxEpisodeListSettings.filter
        let hidesQueuedEpisodes = appModel.inboxEpisodeListSettings.hidesQueuedEpisodes
        let groupsByPodcast = appModel.inboxEpisodeListSettings.groupsByPodcast
        // A group counts every matching episode of its show, so grouping
        // reads the whole filtered list instead of a page.
        let model = appModel.coreStoresHydrated
            ? InboxEpisodeListModel.make(
                episodes: inboxEpisodes,
                filter: filter,
                hidesQueuedEpisodes: hidesQueuedEpisodes,
                library: appModel.library,
                downloadRecords: appModel.downloads.records,
                queuedEpisodeIDs: Set(appModel.upNextQueue.items.map(\.episodeID)),
                playingEpisodeID: appModel.playback.currentEpisode?.id.rawValue,
                visibleEpisodeCount: groupsByPodcast ? nil : visibleEpisodeCount
            )
            : InboxEpisodeListModel(episodes: [], totalEpisodeCount: 0, hasMore: false)
        // Nil while the Inbox lists episodes.
        let groups = groupsByPodcast
            ? InboxPodcastGroup.make(episodes: model.episodes, subscriptions: appModel.library.subscriptions)
            : nil
        let visibleEpisodes = groups == nil ? Array(model.episodes.prefix(visibleEpisodeCount)) : []
        let rowIDs = groups?.map(\.id) ?? visibleEpisodes.map(\.episodeID)
        // The filter applies only to a hydrated, populated Inbox, as the list
        // branches below; a persisted filter never labels the loading state.
        let showsFilter = appModel.coreStoresHydrated && !inboxEpisodes.isEmpty
        let layout = groupedLayout

        content(
            model: model,
            hasInboxEpisodes: !inboxEpisodes.isEmpty,
            filter: filter,
            hidesQueuedEpisodes: hidesQueuedEpisodes,
            groups: groups,
            visibleEpisodes: visibleEpisodes,
            layout: layout
        )
        .animation(listAnimation, value: rowIDs)
        .animation(listAnimation, value: appModel.library.state)
        .animation(listAnimation, value: groupsByPodcast)
        .animation(listAnimation, value: layout)
        .animation(listAnimation, value: appModel.library.lastRefreshWasOffline)
        .safeAreaInset(edge: .top, spacing: 0) {
            SettingsErrorBanner(message: appModel.inboxEpisodeListSettings.lastErrorMessage)
        }
        .navigationTitle("Inbox")
        // An empty subtitle takes no space under the large title.
        .navigationSubtitle(
            showsFilter ? appModel.inboxEpisodeListSettings.activeFilterTitles.joined(separator: " · ") : ""
        )
        .toolbarMinimizationBehavior(.onScrollDown, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                InboxAdDetectionToolbarStatus(onOpen: onOpenAdDetectionQueue)
            }
            if showsFilter {
                if groupsByPodcast {
                    ToolbarItem(placement: .topBarTrailing) {
                        InboxGroupedLayoutMenu(resolvedLayout: layout)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    InboxFilterMenu()
                }
            }
        }
        .refreshable {
            await appModel.library.refreshAll(modelContext: modelContext)
        }
    }

    /// The grid is its own scroll view, so each branch brings its container
    /// instead of sharing one `List`.
    @ViewBuilder
    private func content(
        model: InboxEpisodeListModel,
        hasInboxEpisodes: Bool,
        filter: PodcastEpisodeFilter,
        hidesQueuedEpisodes: Bool,
        groups: [InboxPodcastGroup]?,
        visibleEpisodes: [EpisodeListItemSnapshot],
        layout: LibraryLayout
    ) -> some View {
        if !appModel.coreStoresHydrated {
            inboxList {
                InboxLoadingStateView()
            }
        } else if case .failed(let message) = appModel.library.state,
                  !hasInboxEpisodes {
            inboxList {
                InboxFailedStateView(message: message)
            }
        } else if !hasInboxEpisodes {
            inboxList {
                InboxEmptyStateView(
                    syncActivity: appModel.syncStatus.libraryActivity,
                    onAdd: onAdd
                )
            }
        } else if model.isFilteredEmpty {
            inboxList {
                InboxFilteredEmptyStateView(
                    filter: filter,
                    hidesQueuedEpisodes: hidesQueuedEpisodes,
                    onShowAll: showAllEpisodes
                )
            }
        } else if let groups {
            let episodeListOverride = PodcastEpisodeListOverride(
                filter: filter,
                hidesQueuedEpisodes: hidesQueuedEpisodes
            )
            if layout == .grid {
                InboxPodcastGroupGrid(groups: groups, episodeListOverride: episodeListOverride) {
                    if appModel.library.lastRefreshWasOffline {
                        LibraryOfflineNotice()
                    }
                }
                .transition(.opacity)
            } else {
                inboxList {
                    ForEach(groups) { group in
                        InboxPodcastGroupLink(group: group, episodeListOverride: episodeListOverride) {
                            SubscriptionRowView(subscription: group.subscription, badgeCount: group.episodeCount)
                        }
                    }
                }
                .accessibilityIdentifier("Inbox Podcast List")
                .transition(.opacity)
            }
        } else {
            inboxList {
                ForEach(visibleEpisodes) { episode in
                    EpisodeRowButton(
                        episode: episode,
                        onOpenEpisode: onOpenEpisode
                    )
                    .modifier(PodcastEpisodeSwipeActionsModifier(episode: episode))
                }
                EpisodeCatalogContinuation(hasMore: model.hasMore, visibleCount: $visibleEpisodeCount)
            }
        }
    }

    private func inboxList<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        List {
            offlineNoticeSection
            content()
        }
        .listSectionSpacing(12)
        .contentMargins(.horizontal, horizontalSizeClass == .regular ? 32 : nil, for: .scrollContent)
    }

    @ViewBuilder
    private var offlineNoticeSection: some View {
        if appModel.library.lastRefreshWasOffline {
            Section {
                LibraryOfflineNotice()
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
        }
    }

    private var listAnimation: Animation? {
        reduceMotion ? nil : .default
    }

    private func showAllEpisodes() {
        appModel.inboxEpisodeListSettings.resetToDefaults(modelContext: modelContext)
    }
}

/// Reads the ad-detection queue snapshot in its own body so per-stage queue
/// churn (transcription progress publishes many stage updates per episode)
/// re-evaluates this indicator alone, never the inbox List above it.
private struct InboxAdDetectionToolbarStatus: View {
    @Environment(OpenCastAppModel.self) private var appModel

    let onOpen: () -> Void

    var body: some View {
        let snapshot = appModel.adFreePass.queueSnapshot
        AdDetectionQueueToolbarIndicator(
            indicator: adDetectionIndicator(for: snapshot),
            accessibilityValue: adDetectionAccessibilityValue(for: snapshot),
            onOpen: onOpen
        )
    }

    private func adDetectionIndicator(
        for snapshot: AdFreePassQueueSnapshot
    ) -> AdDetectionQueuePresentation.Indicator {
        let hasFailures = snapshot.failedCount > 0
        return switch snapshot.state {
        case .idle:
            snapshot.outcomes.isEmpty ? .hidden : .finished(hasFailures: hasFailures)
        case .running:
            .running(
                fractionCompleted: snapshot.fractionCompleted,
                hasFailures: hasFailures
            )
        case .pausedInterrupted, .awaitingModelConsent, .capDeferred:
            .paused(hasFailures: hasFailures)
        }
    }

    private func adDetectionAccessibilityValue(for snapshot: AdFreePassQueueSnapshot) -> String {
        let percent = Int((snapshot.fractionCompleted * 100).rounded())
        return switch snapshot.state {
        case .idle:
            snapshot.outcomes.isEmpty
                ? "Idle"
                : "Finished — \(snapshot.completedCount) detected, \(snapshot.failedCount) failed"
        case .running:
            "\(percent)% — detecting ads"
        case .pausedInterrupted:
            "\(percent)% — paused"
        case .awaitingModelConsent:
            "\(percent)% — waiting for the speech model"
        case .capDeferred:
            "\(percent)% — " + EpisodeAdFreePassPresentation.capDeferred.statusText
        }
    }
}
