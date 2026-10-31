import SwiftData
import SwiftUI

/// Edit, share and delete for one episode's notes, and the errors they
/// raise; owned by whichever container lists the notes.
@Observable
final class EpisodeNotesActions {
    var editDraft: EpisodeNoteDraft?
    var shareExport: EpisodeNotesShare?
    var openErrorMessage: String?
    var shareErrorMessage: String?
    var deleteErrorMessage: String?

    func edit(_ note: EpisodeNoteRecord, episodeTitle: String) {
        editDraft = EpisodeNoteDraft(
            episodeID: note.episodeID,
            episodeTitle: episodeTitle,
            timestamp: note.timestamp,
            noteID: note.noteID,
            initialText: note.text,
            isEpisodeWide: note.isEpisodeWide
        )
    }

    func addEpisodeNote(episodeID: String, episodeTitle: String, in context: ModelContext) {
        do {
            let existing = try EpisodeNoteStore.wholeEpisodeNote(for: episodeID, in: context)
            editDraft = .wholeEpisode(episodeID: episodeID, episodeTitle: episodeTitle, existing: existing)
        } catch {
            openErrorMessage = error.localizedDescription
        }
    }

    func share(_ notes: [EpisodeNoteRecord], episodeTitle: String, showTitle: String) {
        do {
            shareExport = try EpisodeNotesShare(episodeTitle: episodeTitle, showTitle: showTitle, notes: notes)
        } catch {
            shareErrorMessage = error.localizedDescription
        }
    }

    func delete(_ note: EpisodeNoteRecord, in context: ModelContext) {
        do {
            try EpisodeNoteStore.delete(note, in: context)
        } catch {
            deleteErrorMessage = error.localizedDescription
        }
    }
}
