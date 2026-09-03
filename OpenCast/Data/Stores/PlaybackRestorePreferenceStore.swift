import Foundation
import SwiftData
import os

/// Device-local memory of the last-played episode — the key launch restore
/// reads. Lives in `LocalPreferenceRecord` with the rest of the wipeable
/// local state.
final class PlaybackRestorePreferenceStore {
    private static let logger = Logger(subsystem: "com.connor.opencast", category: "PlaybackRestoreState")
    static let episodeIDKey = "playback.lastEpisodeID"
    // The periodic flush calls remember every tick; the cached record makes
    // the unchanged-episode tick a pure no-op instead of a refetch plus a
    // guaranteed dirty save.
    private var recordCache: LocalPreferenceRecord?

    func storedEpisodeID(modelContext: ModelContext) -> String? {
        preference(modelContext: modelContext)?.value.trimmedNonEmpty
    }

    func remember(_ episodeID: String, modelContext: ModelContext) {
        if recordCache?.value == episodeID {
            return
        }

        let record: LocalPreferenceRecord
        if let cachedRecord = recordCache {
            record = cachedRecord
        } else if let existingRecord = preference(modelContext: modelContext) {
            recordCache = existingRecord
            guard existingRecord.value != episodeID else {
                return
            }
            record = existingRecord
        } else {
            record = LocalPreferenceRecord(key: Self.episodeIDKey, value: episodeID)
            modelContext.insert(record)
            recordCache = record
        }

        record.value = episodeID
        record.updatedAt = .now
        do {
            try modelContext.save()
        } catch {
            Self.logger.error("Unable to persist the last-playback episode: \(error.localizedDescription)")
        }
    }

    func clear(modelContext: ModelContext) {
        recordCache = nil
        let records = preferences(modelContext: modelContext)
        guard !records.isEmpty else {
            return
        }

        for record in records {
            modelContext.delete(record)
        }
        do {
            try modelContext.save()
        } catch {
            Self.logger.error("Unable to clear the last-playback episode: \(error.localizedDescription)")
        }
    }

    func resetAfterDataNuke() {
        recordCache = nil
    }

    private func preference(modelContext: ModelContext) -> LocalPreferenceRecord? {
        preferences(modelContext: modelContext).first
    }

    private func preferences(modelContext: ModelContext) -> [LocalPreferenceRecord] {
        let key = Self.episodeIDKey
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
