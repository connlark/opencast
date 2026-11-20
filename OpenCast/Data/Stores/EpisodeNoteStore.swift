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

    private typealias EpisodeInfo = (podcastID: String, podcastTitle: String, episodeTitle: String, artworkURL: String?)

    static func notes(for episodeID: String) -> FetchDescriptor<EpisodeNoteRecord> {
        FetchDescriptor(
            predicate: #Predicate { $0.episodeID == episodeID },
            sortBy: [SortDescriptor(\.timestamp), SortDescriptor(\.createdAt)]
        )
    }

    static func allNotes() -> FetchDescriptor<EpisodeNoteRecord> {
        FetchDescriptor(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
    }

    static func noteCount(in context: ModelContext) throws -> Int {
        try context.fetchCount(FetchDescriptor<EpisodeNoteRecord>())
    }

    static func noteTimestamps(for episodeID: String, in context: ModelContext) throws -> [TimeInterval] {
        try context.fetch(FetchDescriptor<EpisodeNoteRecord>(
            predicate: #Predicate { $0.episodeID == episodeID && $0.isEpisodeWide == false }
        )).map(\.timestamp)
    }

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
            let previousInfo = episodeInfo(of: existing)
            let previousUpdatedAt = existing.updatedAt
            existing.text = trimmed
            existing.updatedAt = .now
            applyEpisodeInfo(from: draft, to: existing)
            do { try save(context) } catch {
                existing.text = previousText
                restore(previousInfo, to: existing)
                existing.updatedAt = previousUpdatedAt
                throw error
            }
            return existing
        }
        let note = EpisodeNoteRecord(episodeID: episodeID, timestamp: draft.isEpisodeWide ? 0 : draft.timestamp, text: trimmed)
        note.isEpisodeWide = draft.isEpisodeWide
        applyEpisodeInfo(from: draft, to: note)
        context.insert(note)
        do { try save(context) } catch {
            context.delete(note)
            throw error
        }
        return note
    }

    static func backfillEpisodeInfo(
        _ notes: [EpisodeNoteRecord],
        resolve: (String) -> EpisodeListItemSnapshot?,
        in context: ModelContext,
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) throws {
        var filled: [(note: EpisodeNoteRecord, previous: EpisodeInfo)] = []
        for note in notes where isMissingEpisodeInfo(note) {
            guard let episode = resolve(note.episodeID) else { continue }
            let previous = episodeInfo(of: note)
            if note.podcastID.isEmpty, !episode.podcastID.isEmpty {
                note.podcastID = episode.podcastID
            }
            if note.podcastTitle.isEmpty, !episode.podcastTitle.isEmpty {
                note.podcastTitle = episode.podcastTitle
            }
            if note.episodeTitle.isEmpty, !episode.title.isEmpty {
                note.episodeTitle = episode.title
            }
            if note.artworkURL?.isEmpty ?? true, let artworkURL = episode.artworkURL, !artworkURL.isEmpty {
                note.artworkURL = artworkURL
            }
            if episodeInfo(of: note) != previous {
                filled.append((note, previous))
            }
        }
        guard !filled.isEmpty else { return }
        do {
            try save(context)
        } catch {
            for (note, previous) in filled { restore(previous, to: note) }
            throw error
        }
    }

    /// Skips empty details so an edit from a surface that lacks one keeps the stored value.
    private static func applyEpisodeInfo(from draft: EpisodeNoteDraft, to note: EpisodeNoteRecord) {
        if !draft.podcastID.isEmpty { note.podcastID = draft.podcastID }
        if !draft.podcastTitle.isEmpty { note.podcastTitle = draft.podcastTitle }
        if !draft.episodeTitle.isEmpty { note.episodeTitle = draft.episodeTitle }
        if let artworkURL = draft.artworkURL, !artworkURL.isEmpty { note.artworkURL = artworkURL }
    }

    private static func isMissingEpisodeInfo(_ note: EpisodeNoteRecord) -> Bool {
        note.podcastID.isEmpty || note.podcastTitle.isEmpty || note.episodeTitle.isEmpty
            || (note.artworkURL?.isEmpty ?? true)
    }

    private static func episodeInfo(of note: EpisodeNoteRecord) -> EpisodeInfo {
        (note.podcastID, note.podcastTitle, note.episodeTitle, note.artworkURL)
    }

    private static func restore(_ info: EpisodeInfo, to note: EpisodeNoteRecord) {
        note.podcastID = info.podcastID
        note.podcastTitle = info.podcastTitle
        note.episodeTitle = info.episodeTitle
        note.artworkURL = info.artworkURL
    }
}
