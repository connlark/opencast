import SwiftData
import SwiftUI

struct InboxView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.modelContext) private var modelContext

    let onAdd: () -> Void
    let onOpenEpisode: (String) -> Void
    var onOpenAdDetectionQueue: () -> Void = {}

    private var adDetectionPresentation: AdDetectionQueuePresentation {
        AdDetectionQueuePresentation(
            snapshot: appModel.adFreePass.queueSnapshot,
            isBackgroundSessionArmed: appModel.adFreePassBackgroundSession.isArmed
        )
    }

    var body: some View {
        let inboxEpisodes = appModel.library.inboxEpisodes
        let episodeIDs = inboxEpisodes.map(\.episodeID)

        List {
            if appModel.library.state == .loading && inboxEpisodes.isEmpty {
                InboxLoadingStateView()
            } else if case .failed(let message) = appModel.library.state,
                      inboxEpisodes.isEmpty {
                InboxFailedStateView(message: message)
            } else if inboxEpisodes.isEmpty {
                InboxEmptyStateView(
                    syncActivity: appModel.syncStatus.libraryActivity,
                    onAdd: onAdd
                )
            } else {
                ForEach(inboxEpisodes) { episode in
                    EpisodeRowButton(
                        episode: episode,
                        onOpenEpisode: onOpenEpisode
                    )
                }
            }
        }
        .contentMargins(.horizontal, horizontalSizeClass == .regular ? 32 : nil, for: .scrollContent)
        .animation(listAnimation, value: episodeIDs)
        .animation(listAnimation, value: appModel.library.state)
        .navigationTitle("Inbox")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                AdDetectionQueueToolbarIndicator(
                    indicator: adDetectionPresentation.indicator,
                    accessibilityValue: adDetectionPresentation.accessibilityValue,
                    onOpen: onOpenAdDetectionQueue
                )
            }
        }
        .refreshable {
            await appModel.library.refreshAll(modelContext: modelContext)
        }
    }

    private var listAnimation: Animation? {
        reduceMotion ? nil : .default
    }
}
