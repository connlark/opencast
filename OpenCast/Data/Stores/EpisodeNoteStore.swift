import Foundation
import SwiftData

// Undo only note mutations on failure; a context-wide rollback would discard
// unrelated pending changes in the shared model context.
enum EpisodeNoteStore {
    enum ValidationError: LocalizedError {
        case emptyNote
        case invalidPosition
        case missingNote

        var errorDescription: String? {
            switch self {
            case .emptyNote: "Enter a note before saving."
            case .missingNote: "This note is no longer available."
            case .invalidPosition: "The episode or playback position is unavailable."
            }
        }
    }

    /// One episode's notes in timeline order, for the views that list them.
    static func notes(for episodeID: String) -> FetchDescriptor<EpisodeNoteRecord> {
        FetchDescriptor(
            predicate: #Predicate { $0.episodeID == episodeID },
            sortBy: [SortDescriptor(\.timestamp), SortDescriptor(\.createdAt)]
        )
    }

    /// The episode's single whole-episode note, if one has been saved.
    static func wholeEpisodeNote(for episodeID: String, in context: ModelContext) throws -> EpisodeNoteRecord? {
        var descriptor = FetchDescriptor<EpisodeNoteRecord>(
            predicate: #Predicate { $0.episodeID == episodeID && $0.isEpisodeWide }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    static func delete(
        _ note: EpisodeNoteRecord,
        in context: ModelContext,
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) throws {
        context.delete(note)
        do {
            try save(context)
        } catch {
            context.insert(note)
            throw error
        }
    }

    static func deleteAll(
        in context: ModelContext,
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) throws {
        let notes = try context.fetch(FetchDescriptor<EpisodeNoteRecord>())
        for note in notes { context.delete(note) }
        do {
            try save(context)
        } catch {
            for note in notes { context.insert(note) }
            throw error
        }
    }

    @discardableResult
    static func save(
        _ text: String,
        for draft: EpisodeNoteDraft,
        in context: ModelContext,
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) throws -> EpisodeNoteRecord {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ValidationError.emptyNote }
        guard !draft.episodeID.isEmpty,
              draft.isEpisodeWide || (draft.timestamp.isFinite && draft.timestamp >= 0) else {
            throw ValidationError.invalidPosition
        }
        let episodeID = draft.episodeID
        let existing: EpisodeNoteRecord?
        if let noteID = draft.noteID {
            existing = try context.fetch(FetchDescriptor<EpisodeNoteRecord>(
                predicate: #Predicate { $0.noteID == noteID && $0.episodeID == episodeID }
            )).first
            guard existing != nil else { throw ValidationError.missingNote }
        } else if draft.isEpisodeWide {
            existing = try wholeEpisodeNote(for: episodeID, in: context)
        } else {
            existing = nil
        }
        if let existing {
            let previousText = existing.text
            existing.text = trimmed
            do { try save(context) } catch {
                existing.text = previousText
                throw error
            }
            return existing
        }
        let note = EpisodeNoteRecord(episodeID: episodeID, timestamp: draft.isEpisodeWide ? 0 : draft.timestamp, text: trimmed)
        note.isEpisodeWide = draft.isEpisodeWide
        context.insert(note)
        do { try save(context) } catch {
            context.delete(note)
            throw error
        }
        return note
    }
}
