import Foundation
import SwiftData
import os

final class PlaybackRestorePreferenceStore {
    private static let logger = Logger(subsystem: "com.connor.opencast", category: "PlaybackRestoreState")
    static let episodeIDKey = "playback.lastEpisodeID"
    static let sourcePlaylistIDKey = "playback.currentSourcePlaylistID"
    // Makes an unchanged pair a no-op on every flush tick. A nil source means its row is absent.
    private var rememberedPair: (episodeID: String, sourcePlaylistID: String?)?
    // A failed save leaves its edits pending in the shared context, so the next upsert reports no
    // change; this makes that tick retry the save instead of marking the pair saved.
    private var hasUnsavedChanges = false

    func storedEpisodeID(modelContext: ModelContext) -> String? {
        preferences(forKey: Self.episodeIDKey, modelContext: modelContext).first?.value.trimmedNonEmpty
    }

    func storedSourcePlaylistID(modelContext: ModelContext) -> String? {
        preferences(forKey: Self.sourcePlaylistIDKey, modelContext: modelContext).first?.value.trimmedNonEmpty
    }

    func remember(_ episodeID: String, sourcePlaylistID: String?, modelContext: ModelContext) {
        let sourcePlaylistID = sourcePlaylistID?.trimmedNonEmpty
        if let rememberedPair,
           rememberedPair.episodeID == episodeID,
           rememberedPair.sourcePlaylistID == sourcePlaylistID {
            return
        }

        var changed = upsert(Self.episodeIDKey, value: episodeID, modelContext: modelContext)
        if let sourcePlaylistID {
            changed = upsert(Self.sourcePlaylistIDKey, value: sourcePlaylistID, modelContext: modelContext) || changed
        } else {
            let sourceRecords = preferences(forKey: Self.sourcePlaylistIDKey, modelContext: modelContext)
            for record in sourceRecords {
                modelContext.delete(record)
            }
            changed = changed || !sourceRecords.isEmpty
        }

        guard changed || hasUnsavedChanges else {
            rememberedPair = (episodeID: episodeID, sourcePlaylistID: sourcePlaylistID)
            return
        }

        do {
            try modelContext.save()
            hasUnsavedChanges = false
            rememberedPair = (episodeID: episodeID, sourcePlaylistID: sourcePlaylistID)
        } catch {
            hasUnsavedChanges = true
            rememberedPair = nil
            Self.logger.error("Unable to persist the last-playback episode: \(error.localizedDescription)")
        }
    }

    func clear(modelContext: ModelContext) {
        rememberedPair = nil
        let records = preferences(forKey: Self.episodeIDKey, modelContext: modelContext)
            + preferences(forKey: Self.sourcePlaylistIDKey, modelContext: modelContext)
        guard !records.isEmpty else {
            return
        }

        for record in records {
            modelContext.delete(record)
        }
        do {
            try modelContext.save()
            hasUnsavedChanges = false
        } catch {
            Self.logger.error("Unable to clear the last-playback episode: \(error.localizedDescription)")
        }
    }

    func resetAfterDataNuke() {
        rememberedPair = nil
        hasUnsavedChanges = false
    }

    /// Returns whether the context now holds an unsaved change for the key.
    private func upsert(_ key: String, value: String, modelContext: ModelContext) -> Bool {
        if let record = preferences(forKey: key, modelContext: modelContext).first {
            guard record.value != value else {
                return false
            }
            record.value = value
            record.updatedAt = .now
        } else {
            modelContext.insert(LocalPreferenceRecord(key: key, value: value))
        }
        return true
    }

    private func preferences(forKey key: String, modelContext: ModelContext) -> [LocalPreferenceRecord] {
        let descriptor = FetchDescriptor<LocalPreferenceRecord>(
            predicate: #Predicate<LocalPreferenceRecord> { record in
                record.key == key
            },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        do {
            return try modelContext.fetch(descriptor)
        } catch {
            Self.logger.error("Unable to fetch the last-playback preference: \(error.localizedDescription)")
            return []
        }
    }
}
