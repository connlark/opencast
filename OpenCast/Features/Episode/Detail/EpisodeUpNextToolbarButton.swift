import SwiftData
import SwiftUI

/// The episode page's Add to Up Next toolbar control, beside Episode Actions.
/// Not queued, a tap queues the episode next and touch and hold offers Play
/// Next / Play Last. Once queued, a tap opens the menu, which adds Remove from
/// Up Next, so a tap never moves a queued episode.
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
        // A toolbar item drops `accessibilityValue`, so the label carries
        // the queued state.
        Group {
            if state.isQueued {
                Menu {
                    queueButtons(state)
                    Button("Remove from Up Next", systemImage: "minus.circle", role: .destructive, action: remove)
                } label: {
                    Label("In Up Next", systemImage: "text.badge.checkmark")
                }
            } else {
                Menu {
                    queueButtons(state)
                } label: {
                    Label("Add to Up Next", systemImage: "text.badge.plus")
                } primaryAction: {
                    playNext()
                }
            }
        }
        .disabled(!state.canEnqueue)
        .accessibilityInputLabels(["Add to Up Next", "In Up Next"])
        .accessibilityIdentifier(Self.accessibilityIdentifier)
    }

    private func queueButtons(_ state: EpisodeUpNextMenuState) -> some View {
        EpisodeUpNextMenuButtons(state: state, onPlayNext: playNext, onPlayLast: playLast)
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
