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

    var body: some View {
        let hidesPlayedEpisodes = appModel.inboxSettings.hidesPlayedEpisodes
        let hidesQueuedEpisodes = appModel.inboxSettings.hidesQueuedEpisodes
        let inboxEpisodes = appModel.library.inboxEpisodes.filter { episode in
            if hidesPlayedEpisodes && appModel.library.progressSummary(for: episode).isCompleted {
                return false
            }
            if hidesQueuedEpisodes {
                let isQueued = appModel.upNextQueue.contains(episodeID: episode.episodeID)
                let isCurrentEpisode = appModel.playback.currentEpisode?.id.rawValue == episode.episodeID
                if isQueued || isCurrentEpisode {
                    return false
                }
            }
            return true
        }
        let visibleEpisodes = inboxEpisodes.prefix(visibleEpisodeCount)
        let episodeIDs = visibleEpisodes.map(\.episodeID)

        List {
            if appModel.library.state == .loading && inboxEpisodes.isEmpty {
                InboxLoadingStateView()
            } else if case .failed(let message) = appModel.library.state,
                      inboxEpisodes.isEmpty {
                InboxFailedStateView(message: message)
            } else if inboxEpisodes.isEmpty && (hidesPlayedEpisodes || hidesQueuedEpisodes) {
                ContentUnavailableView {
                    Label("No Episodes", systemImage: "checkmark.circle")
                } description: {
                    Text(filteredEmptyStateDescription(showsUnplayedOnly: hidesPlayedEpisodes, hidesQueuedEpisodes: hidesQueuedEpisodes))
                }
            } else if inboxEpisodes.isEmpty {
                InboxEmptyStateView(
                    syncActivity: appModel.syncStatus.libraryActivity,
                    onAdd: onAdd
                )
            } else {
                ForEach(visibleEpisodes) { episode in
                    EpisodeRowButton(
                        episode: episode,
                        onOpenEpisode: onOpenEpisode
                    )
                    .modifier(PodcastEpisodeSwipeActionsModifier(episode: episode))
                }
                EpisodeCatalogContinuation(totalCount: inboxEpisodes.count, visibleCount: $visibleEpisodeCount)
            }
        }
        .contentMargins(.horizontal, horizontalSizeClass == .regular ? 32 : nil, for: .scrollContent)
        .animation(listAnimation, value: episodeIDs)
        .animation(listAnimation, value: appModel.library.state)
        .navigationTitle("Inbox")
        .toolbarMinimizationBehavior(.onScrollDown, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                InboxAdDetectionToolbarStatus(onOpen: onOpenAdDetectionQueue)
            }
        }
        .refreshable {
            await appModel.library.refreshAll(modelContext: modelContext)
        }
    }

    private var listAnimation: Animation? {
        reduceMotion ? nil : .default
    }

    private func filteredEmptyStateDescription(showsUnplayedOnly: Bool, hidesQueuedEpisodes: Bool) -> String {
        switch (showsUnplayedOnly, hidesQueuedEpisodes) {
        case (true, true):
            "Every episode is either played or already in Up Next."
        case (true, false):
            "Every episode in your inbox is marked as played."
        case (false, true):
            "Every episode in your inbox is already in Up Next."
        case (false, false):
            ""
        }
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
