import SwiftData
import SwiftUI

/// The playlist detail toolbar menu: Play Next, Play Last and Download All,
/// then reorder, rename, sort, Hide Played and delete. Reorder, sort and Hide
/// Played are manual only: a smart playlist's rule decides its order and
/// membership, so it passes no edit mode and Edit does not show. Deleting
/// pops back to the collection.
struct PlaylistActionsMenu: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let summary: PlaylistSummary
    /// Whether Edit can start; read only alongside `editMode`.
    var canEdit = false
    let canEnqueue: Bool
    let canDownloadAll: Bool
    var editMode: Binding<EditMode>?
    @State private var namePromptRequest: PlaylistNamePromptRequest?
    @State private var isConfirmingDelete = false
    @State private var isConfirmingDownloadAll = false
    @State private var isShowingNothingToDownload = false
    @State private var downloadAllCount = 0

    var body: some View {
        Menu {
            Button(
                "Play Next",
                systemImage: "text.line.first.and.arrowtriangle.forward",
                action: enqueueNext
            )
            .disabled(!canEnqueue)

            Button(
                "Play Last",
                systemImage: "text.line.last.and.arrowtriangle.forward",
                action: enqueueLast
            )
            .disabled(!canEnqueue)

            Button("Download All", systemImage: "arrow.down.circle", action: confirmDownloadAll)
                .disabled(!canDownloadAll)

            Divider()

            if let editMode {
                Button(
                    editMode.wrappedValue.isEditing ? "Done" : "Edit",
                    systemImage: "arrow.up.arrow.down.circle",
                    action: toggleEditMode
                )
                .disabled(!canEdit && !editMode.wrappedValue.isEditing)
            }

            Button("Rename", systemImage: "pencil", action: promptRename)

            if summary.kind == .manual {
                Menu(PlaylistOrganizerCopy.sortEpisodes, systemImage: "arrow.up.arrow.down") {
                    Button(PlaylistItemSortOrder.oldestFirst.title, action: sortOldestFirst)
                    Button(PlaylistItemSortOrder.newestFirst.title, action: sortNewestFirst)
                }

                Toggle("Hide Played", systemImage: "eye.slash", isOn: hidesPlayedBinding)
            }

            Divider()

            Button("Delete Playlist", systemImage: "trash", role: .destructive, action: confirmDelete)
        } label: {
            Label("Playlist Actions", systemImage: "ellipsis.circle")
        }
        .accessibilityIdentifier("Playlist Actions")
        .confirmationDialog(
            "Delete \u{201C}\(summary.name)\u{201D}?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Playlist", role: .destructive, action: deletePlaylist)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its episodes stay in your library.")
        }
        .confirmationDialog(
            downloadAllTitle,
            isPresented: $isConfirmingDownloadAll,
            titleVisibility: .visible
        ) {
            Button(downloadAllConfirmTitle, action: downloadAll)
            Button("Cancel", role: .cancel) {}
        }
        .alert("Nothing to Download", isPresented: $isShowingNothingToDownload) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Every unplayed episode in this playlist is downloaded or downloading.")
        }
        .playlistNamePrompt($namePromptRequest, onCommit: commitName(_:name:))
    }

    private var hidesPlayedBinding: Binding<Bool> {
        Binding(
            get: { summary.hidesPlayed },
            set: { hidesPlayed in
                setHidesPlayed(hidesPlayed)
            }
        )
    }

    // Grammar agreement resolves only on the attributed localization path.
    private var downloadAllConfirmTitle: String {
        String(AttributedString(localized: "Download ^[\(downloadAllCount) Episode](inflect: true)").characters)
    }

    private var downloadAllTitle: String {
        String(AttributedString(localized: "Download ^[\(downloadAllCount) Episode](inflect: true)?").characters)
    }

    private func enqueueNext() {
        appModel.enqueuePlaylist(summary.playlistID, position: .next, modelContext: modelContext)
    }

    private func enqueueLast() {
        appModel.enqueuePlaylist(summary.playlistID, position: .last, modelContext: modelContext)
    }

    // The candidates are resolved at tap time, not in `body`: resolving them
    // checks each downloaded file on disk, so the enabled state is only a
    // record-level gate and the empty case can still race in. Taking the
    // count here also holds the title steady while the downloads commit.
    private func confirmDownloadAll() {
        let count = appModel.playlistDownloadAllCandidates(summary.playlistID).count
        guard count > 0 else {
            isShowingNothingToDownload = true
            return
        }
        downloadAllCount = count
        isConfirmingDownloadAll = true
    }

    private func downloadAll() {
        appModel.downloadAllPlaylistEpisodes(summary.playlistID, modelContext: modelContext)
    }

    private func toggleEditMode() {
        guard let editMode else {
            return
        }
        withAnimation {
            editMode.wrappedValue = editMode.wrappedValue.isEditing ? .inactive : .active
        }
    }

    private func promptRename() {
        namePromptRequest = .rename(summary)
    }

    private func commitName(_ request: PlaylistNamePromptRequest, name: String) {
        guard case .rename(let playlistID) = request.kind else {
            return
        }
        appModel.renamePlaylist(playlistID, to: name, modelContext: modelContext)
    }

    private func sortOldestFirst() {
        sortItems(by: .oldestFirst)
    }

    private func sortNewestFirst() {
        sortItems(by: .newestFirst)
    }

    private func sortItems(by order: PlaylistItemSortOrder) {
        appModel.performPlaylistMutation {
            appModel.playlists.sortItems(in: summary.playlistID, by: order, modelContext: modelContext)
        }
    }

    private func setHidesPlayed(_ hidesPlayed: Bool) {
        appModel.performPlaylistMutation {
            appModel.playlists.setHidesPlayed(
                hidesPlayed,
                for: summary.playlistID,
                modelContext: modelContext
            )
        }
    }

    private func confirmDelete() {
        isConfirmingDelete = true
    }

    private func deletePlaylist() {
        let isDeleted = appModel.deletePlaylist(summary.playlistID, modelContext: modelContext)
        if isDeleted {
            dismiss()
        }
    }
}
