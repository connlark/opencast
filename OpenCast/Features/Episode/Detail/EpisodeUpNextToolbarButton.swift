import SwiftData
import SwiftUI

/// The episode page's Add to Up Next toolbar control, beside Episode Actions.
/// A tap always opens its menu, Play Next and Play Last, plus Remove from Up
/// Next once the episode is queued, so a tap alone never queues, moves or
/// removes anything.
struct EpisodeUpNextToolbarButton: View {
    static let accessibilityIdentifier = "Episode Up Next Control"

    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    let episode: EpisodeListItemSnapshot
    /// Called once for each queueing the store saved; the page plays the
    /// haptic.
    let onEnqueued: () -> Void

    var body: some View {
        let state = appModel.upNextMenuState(for: episode)
        Menu {
            EpisodeUpNextMenuButtons(state: state, onPlayNext: playNext, onPlayLast: playLast)
            if state.isQueued {
                Button("Remove from Up Next", systemImage: "minus.circle", role: .destructive, action: remove)
            }
        } label: {
            // A toolbar item drops `accessibilityValue`, so the label carries
            // the queued state.
            Label(
                state.isQueued ? "In Up Next" : "Add to Up Next",
                systemImage: state.isQueued ? "text.badge.checkmark" : "text.badge.plus"
            )
        }
        .disabled(!state.canEnqueue)
        .accessibilityInputLabels(["Add to Up Next", "In Up Next"])
        .accessibilityIdentifier(Self.accessibilityIdentifier)
    }

    private func playNext() {
        enqueue(at: .next)
    }

    private func playLast() {
        enqueue(at: .last)
    }

    private func enqueue(at position: UpNextQueuePosition) {
        if appModel.enqueueInUpNext(episode, at: position, modelContext: modelContext) {
            onEnqueued()
        }
    }

    private func remove() {
        appModel.performUpNextQueueMutation {
            appModel.upNextQueue.remove(episodeID: episode.episodeID, modelContext: modelContext)
        }
    }
}

#Preview("Dark") {
    NavigationStack {
        Text("Episode")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    EpisodeUpNextToolbarButton(episode: .previewSample, onEnqueued: {})
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu("Episode Actions", systemImage: "ellipsis.circle") {}
                }
            }
    }
    .environment(OpenCastAppModel())
    .preferredColorScheme(.dark)
}
