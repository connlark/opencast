import SwiftData
import SwiftUI

/// Play, Play Next, Play Last, Rename and Delete for a playlist in the
/// collection, shared by list rows and grid tiles. Play asks whether to
/// replace Up Next when it already holds episodes. Tiles get the context menu
/// only; swipes do not fit a narrow grid column.
struct PlaylistCollectionActionsModifier: ViewModifier {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @State private var isConfirmingDelete = false
    @State private var isConfirmingReplace = false
    @State private var replaceQueuedCount = 0

    let summary: PlaylistSummary
    let supportsSwipeActions: Bool
    let onRename: (PlaylistSummary) -> Void

    func body(content: Content) -> some View {
        swipeDecoratedContent(content)
            .contextMenu {
                Button("Play", systemImage: "play.fill", action: requestPlay)
                Button(
                    "Play Next",
                    systemImage: "text.line.first.and.arrowtriangle.forward",
                    action: enqueueNext
                )
                Button(
                    "Play Last",
                    systemImage: "text.line.last.and.arrowtriangle.forward",
                    action: enqueueLast
                )
                Divider()
                Button("Rename", systemImage: "pencil", action: rename)
                Divider()
                Button("Delete", systemImage: "trash", role: .destructive, action: confirmDelete)
            }
            .playlistReplaceConfirmation(
                isPresented: $isConfirmingReplace,
                queuedCount: replaceQueuedCount,
                onChoose: play(mode:)
            )
            .confirmationDialog(
                "Delete “\(summary.name)”?",
                isPresented: $isConfirmingDelete,
                titleVisibility: .visible
            ) {
                Button("Delete Playlist", role: .destructive, action: delete)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Its episodes stay in your library.")
            }
    }

    @ViewBuilder
    private func swipeDecoratedContent(_ content: Content) -> some View {
        if supportsSwipeActions {
            content
                .swipeActions(edge: .leading) {
                    Button("Play", systemImage: "play.fill", action: requestPlay)
                        .tint(.accentColor)
                }
                // A destructive role would animate the row away before the
                // confirmation answers, so Delete is only tinted red.
                .swipeActions(edge: .trailing) {
                    Button("Delete", systemImage: "trash", action: confirmDelete)
                        .tint(.red)
                    Button("Rename", systemImage: "pencil", action: rename)
                }
        } else {
            content
        }
    }

    // The queue is read here rather than in `body` so rows and tiles do not
    // re-render on every Up Next change.
    private func requestPlay() {
        let queuedCount = appModel.upNextQueue.items.count
        guard queuedCount > 0 else {
            play(mode: .replace)
            return
        }
        replaceQueuedCount = queuedCount
        isConfirmingReplace = true
    }

    private func play(mode: PlaylistPlayMode) {
        appModel.playPlaylist(summary.playlistID, mode: mode, modelContext: modelContext)
    }

    private func enqueueNext() {
        appModel.enqueuePlaylist(summary.playlistID, position: .next, modelContext: modelContext)
    }

    private func enqueueLast() {
        appModel.enqueuePlaylist(summary.playlistID, position: .last, modelContext: modelContext)
    }

    private func rename() {
        onRename(summary)
    }

    private func confirmDelete() {
        isConfirmingDelete = true
    }

    private func delete() {
        appModel.deletePlaylist(summary.playlistID, modelContext: modelContext)
    }
}
