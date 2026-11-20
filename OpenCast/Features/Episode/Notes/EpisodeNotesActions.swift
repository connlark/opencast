import SwiftData
import SwiftUI

@Observable
final class EpisodeNotesActions {
    var editDraft: EpisodeNoteDraft?
    var shareExport: EpisodeNotesShare?
    var openErrorMessage: String?
    var shareErrorMessage: String?
    var deleteErrorMessage: String?

    func edit(_ note: EpisodeNoteRecord, episode: EpisodeListItemSnapshot?) {
        editDraft = .editing(note, episode: episode)
    }

    func addEpisodeNote(episode: EpisodeListItemSnapshot, in context: ModelContext) {
        do {
            let existing = try EpisodeNoteStore.wholeEpisodeNote(for: episode.episodeID, in: context)
            editDraft = .wholeEpisode(episode: episode, existing: existing)
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

    /// False when the delete failed; the error is in `deleteErrorMessage`.
    func delete(_ note: EpisodeNoteRecord, in context: ModelContext) -> Bool {
        do {
            try EpisodeNoteStore.delete(note, in: context)
            return true
        } catch {
            deleteErrorMessage = error.localizedDescription
            return false
        }
    }
}
