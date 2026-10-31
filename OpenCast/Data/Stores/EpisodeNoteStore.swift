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
            existing = try context.fetch(FetchDescriptor<EpisodeNoteRecord>(
                predicate: #Predicate { $0.episodeID == episodeID && $0.isEpisodeWide }
            )).first
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
