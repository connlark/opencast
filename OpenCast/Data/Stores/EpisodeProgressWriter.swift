import Foundation
import Observation
import OpenCastCore
import SwiftData

/// The synced progress table's writer and published projection: every
/// progress save (through the self-save ledger), the store-ordered record
/// array with its latest-per-episode index, and the revision that rows
/// observe for index membership changes. Store-level presentation — the
/// failed state and the error banner — stays with LibraryStore: every
/// method here throws and the store records the failure.
@Observable
final class EpisodeProgressWriter {
    /// Existing rows observe their SwiftData model directly. This revision
    /// is reserved for index membership changes and out-of-band reloads.
    private(set) var revision = 0
    @ObservationIgnored private var index = EpisodeProgressIndex()
    @ObservationIgnored private let ledger: SyncedStoreSelfSaveLedger

    init(ledger: SyncedStoreSelfSaveLedger) {
        self.ledger = ledger
    }

    var records: [EpisodeProgressRecord] {
        index.records
    }

    /// Reads the tracked revision before the ignored index so a body whose
    /// lookup missed still invalidates once the record appears.
    func latestRecord(for episodeID: String) -> EpisodeProgressRecord? {
        _ = revision
        return index.latest(for: episodeID)
    }

    // MARK: - Projection

    /// Refetches the whole table; store reloads that follow other writes.
    func reload(modelContext: ModelContext) throws {
        replaceAll(try modelContext.fetch(EpisodeProgressIndex.allRecordsDescriptor()))
    }

    /// Refetches and republishes only when the stored rows differ from the
    /// projection; returns whether they did.
    @discardableResult
    func reloadIfChanged(modelContext: ModelContext) throws -> Bool {
        let fetchedRecords = try modelContext.fetch(EpisodeProgressIndex.allRecordsDescriptor())
        guard !EpisodeProgressIndex.records(index.records, match: fetchedRecords) else {
            return false
        }
        replaceAll(fetchedRecords)
        return true
    }

    func replaceAll(_ records: [EpisodeProgressRecord]) {
        if index.replaceAll(records) {
            revision &+= 1
        }
    }

    func reset() {
        index = EpisodeProgressIndex()
        revision &+= 1
    }

    // MARK: - Writes

    /// Returns false when nothing meaningful changed: no save, no credit.
    /// `refreshObservableProgress: false` saves without touching the
    /// projection (flushes from a scene that is not on screen); the next
    /// `reloadIfChanged` publishes the row.
    func update(
        episodeID: String,
        podcastID: String,
        position: TimeInterval,
        duration: TimeInterval?,
        isPlayed: Bool,
        modelContext: ModelContext,
        refreshObservableProgress: Bool
    ) throws -> Bool {
        let updatedRecord: EpisodeProgressRecord
        if let existing = try latestStoredRecord(
            episodeID: episodeID,
            podcastID: podcastID,
            modelContext: modelContext
        ) {
            guard EpisodeProgressRules.hasMeaningfulProgressChange(
                existing,
                position: position,
                duration: duration,
                isPlayed: isPlayed
            ) else {
                return false
            }

            existing.position = position
            existing.duration = duration
            existing.isPlayed = isPlayed
            existing.updatedAt = .now
            updatedRecord = existing
        } else {
            let record = EpisodeProgressRecord(
                episodeID: episodeID,
                podcastID: podcastID,
                position: position,
                duration: duration,
                isPlayed: isPlayed
            )
            modelContext.insert(record)
            updatedRecord = record
        }

        try ledger.save(modelContext)
        if refreshObservableProgress, index.apply(updatedRecord) {
            revision &+= 1
        }
        return true
    }

    /// Marks every listed episode played in one save; returns false when
    /// each record already carried that state.
    func markAllPlayed(
        _ episodes: [EpisodeListItemSnapshot],
        podcastID: String,
        modelContext: ModelContext
    ) throws -> Bool {
        let targetPodcastID = podcastID
        let storedRecords = try modelContext.fetch(
            FetchDescriptor<EpisodeProgressRecord>(
                predicate: #Predicate { record in
                    record.podcastID == targetPodcastID
                }
            )
        )
        let latestRecordByEpisodeID = EpisodeProgressIndex.latestRecordsByEpisodeID(storedRecords)

        let updatedAt = Date.now
        var hasChanges = false
        for episode in episodes {
            let duration = sanitizedDuration(episode.duration)
            let position = duration ?? 0
            if let record = latestRecordByEpisodeID[episode.episodeID] {
                guard EpisodeProgressRules.hasMeaningfulProgressChange(
                    record,
                    position: position,
                    duration: duration,
                    isPlayed: true
                ) else {
                    continue
                }
                record.position = position
                record.duration = duration
                record.isPlayed = true
                record.updatedAt = updatedAt
            } else {
                modelContext.insert(
                    EpisodeProgressRecord(
                        episodeID: episode.episodeID,
                        podcastID: podcastID,
                        position: position,
                        duration: duration,
                        isPlayed: true,
                        updatedAt: updatedAt
                    )
                )
            }
            hasChanges = true
        }

        guard hasChanges else {
            return false
        }

        try ledger.save(modelContext)
        try reload(modelContext: modelContext)
        return true
    }

    /// Deletes the matching progress rows of shows with no subscription
    /// record at all (archived subscriptions still mark a show as
    /// deliberately kept), writing one feed-progress tombstone per cleared
    /// feed when a date is given. Returns how many rows went.
    func deleteUnsubscribedRecords(
        modelContext: ModelContext,
        writingTombstonesAt tombstoneDate: Date?,
        matching isPrunable: (EpisodeProgressRecord) -> Bool
    ) throws -> Int {
        let subscribedFeedURLs = Set(
            try modelContext.fetch(FetchDescriptor<SubscriptionRecord>()).map(\.feedURL)
        )
        let prunableRecords = try modelContext.fetch(EpisodeProgressIndex.allRecordsDescriptor())
            .filter { record in
                !subscribedFeedURLs.contains(record.podcastID) && isPrunable(record)
            }
        guard !prunableRecords.isEmpty else {
            return 0
        }

        for record in prunableRecords {
            modelContext.delete(record)
        }

        if let tombstoneDate {
            let clearedFeedURLs = Set(
                prunableRecords.map { URLCanonicalizer.canonicalString(forRawString: $0.podcastID) }
            )
            for feedURL in clearedFeedURLs {
                modelContext.insert(
                    SyncTombstoneRecord(scope: .feedProgress, feedURL: feedURL, deletedAt: tombstoneDate)
                )
            }
        }

        try ledger.save(modelContext)
        try reloadIfChanged(modelContext: modelContext)
        return prunableRecords.count
    }

    /// Deletes one episode's progress rows and tombstones the episode;
    /// returns false when there was nothing to clear.
    func clear(episodeID: String, podcastID: String, modelContext: ModelContext) throws -> Bool {
        let records = try storedRecords(episodeID: episodeID, podcastID: podcastID, modelContext: modelContext)
        guard !records.isEmpty else {
            return false
        }

        for record in records {
            modelContext.delete(record)
        }
        modelContext.insert(
            SyncTombstoneRecord(
                scope: .episodeProgress,
                feedURL: URLCanonicalizer.canonicalString(forRawString: podcastID),
                episodeID: episodeID
            )
        )

        try ledger.save(modelContext)
        try reloadIfChanged(modelContext: modelContext)
        return true
    }

    // MARK: - Fetches

    private func latestStoredRecord(
        episodeID: String,
        podcastID: String,
        modelContext: ModelContext
    ) throws -> EpisodeProgressRecord? {
        var descriptor = Self.recordsDescriptor(episodeID: episodeID, podcastID: podcastID)
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func storedRecords(
        episodeID: String,
        podcastID: String,
        modelContext: ModelContext
    ) throws -> [EpisodeProgressRecord] {
        try modelContext.fetch(Self.recordsDescriptor(episodeID: episodeID, podcastID: podcastID))
    }

    private static func recordsDescriptor(
        episodeID: String,
        podcastID: String
    ) -> FetchDescriptor<EpisodeProgressRecord> {
        FetchDescriptor<EpisodeProgressRecord>(
            predicate: #Predicate { record in
                record.episodeID == episodeID && record.podcastID == podcastID
            },
            sortBy: [
                SortDescriptor(\.updatedAt, order: .reverse),
                SortDescriptor(\.position, order: .reverse),
                SortDescriptor(\.duration, order: .reverse)
            ]
        )
    }
}
