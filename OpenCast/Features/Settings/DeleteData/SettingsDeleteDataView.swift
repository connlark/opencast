import SwiftData
import SwiftUI

struct SettingsDeleteDataView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    @State private var isConfirmingClearUnfollowedHistory = false
    @State private var isConfirmingDeleteNotes = false
    @State private var noteDeletionError: String?
    @State private var isConfirmingDataNuke = false

    var body: some View {
        Form {
            Section {
                Button(
                    "Clear History for Unfollowed Shows",
                    systemImage: "clock.badge.xmark",
                    role: .destructive,
                    action: confirmClearUnfollowedHistory
                )
                .confirmationDialog(
                    "Clear history for unfollowed shows?",
                    isPresented: $isConfirmingClearUnfollowedHistory,
                    titleVisibility: .visible
                ) {
                    Button("Clear History", role: .destructive, action: clearUnfollowedHistory)
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Played status and playback positions for every show you don't currently follow will be removed, and the change syncs to your other devices.")
                }

                Button("Delete All Private Notes", systemImage: "note.text", role: .destructive) {
                    isConfirmingDeleteNotes = true
                }
                .accessibilityIdentifier("Delete All Private Notes")
                .confirmationDialog(
                    "Delete all private notes?",
                    isPresented: $isConfirmingDeleteNotes,
                    titleVisibility: .visible
                ) {
                    Button("Delete All Private Notes", role: .destructive) { deleteAllNotes() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This permanently deletes all episode notes and timestamped notes on this device.")
                }

                Button(
                    "Nuke opencast Data",
                    systemImage: "trash",
                    role: .destructive,
                    action: confirmDataNuke
                )
                .confirmationDialog(
                    "Nuke all opencast data?",
                    isPresented: $isConfirmingDataNuke,
                    titleVisibility: .visible
                ) {
                    Button("Continue", role: .destructive, action: requestDataNukeConfirmation)
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This starts a final confirmation step before deleting synced subscriptions, synced listening progress, synced playlists, local downloads, caches, and settings.")
                }
            }
        }
        .settingsSubscreen(title: "Delete Data")
        .alert("Couldn’t Delete Private Notes", isPresented: Binding(
            get: { noteDeletionError != nil },
            set: { if !$0 { noteDeletionError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(noteDeletionError ?? "")
        }
    }

    private func confirmClearUnfollowedHistory() {
        isConfirmingClearUnfollowedHistory = true
    }

    private func clearUnfollowedHistory() {
        appModel.library.clearProgressForUnsubscribedShows(modelContext: modelContext)
    }

    private func deleteAllNotes() {
        do {
            try EpisodeNoteStore.deleteAll(in: modelContext)
        } catch {
            noteDeletionError = error.localizedDescription
        }
    }

    private func confirmDataNuke() {
        isConfirmingDataNuke = true
    }

    private func requestDataNukeConfirmation() {
        appModel.requestDataNukeConfirmationPresentation()
    }
}
