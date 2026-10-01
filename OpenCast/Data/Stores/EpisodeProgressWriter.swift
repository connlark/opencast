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
    /// Advances after every write here that can change what a played-state
    /// filter reads (completed, has a position, or a duration that falls
    /// back to the episode's), including an in-place edit `revision`
    /// ignores, for derived readers that cannot observe each record (smart
    /// playlist evaluations). A playback flush that only moves the position
    /// leaves it alone, so listening does not re-evaluate every list. It
    /// also advances when the save of an in-place edit fails, because the
    /// live row keeps the edit. A save with `refreshObservableProgress:
    /// false` leaves its status change pending instead, and the next
    /// observable write or refetch publishes it: that write compares against
    /// the already-updated row, so it cannot see the change on its own.
    private(set) var statusRevision = 0
    /// Set by a suppressed save that changed a status; drained into
    /// `statusRevision` when suppression ends.
    @ObservationIgnored private var hasPendingStatusChange = false
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
        publishStatusChange(false)
    }

    /// Refetches and republishes only when the stored rows differ from the
    /// projection; returns whether they did.
    @discardableResult
    func reloadIfChanged(modelContext: ModelContext) throws -> Bool {
        let fetchedRecords = try modelContext.fetch(EpisodeProgressIndex.allRecordsDescriptor())
        publishStatusChange(false)
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
        hasPendingStatusChange = false
        revision &+= 1
    }

    // MARK: - Writes

    /// Returns false when nothing meaningful changed: no save, no credit.
    /// `refreshObservableProgress: false` saves without touching the
    /// projection (flushes from a scene that is not on screen, or with Now
    /// Playing presented); the next `reloadIfChanged` publishes the row, and
    /// a status change it carried waits for that or the next observable
    /// write.
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
        let changesStatus: Bool
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

            changesStatus = Self.changesStatus(
                existing,
                position: position,
                duration: duration,
                isPlayed: isPlayed
            )
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
            changesStatus = true
        }

        defer {
            if refreshObservableProgress {
                publishStatusChange(changesStatus)
            } else if changesStatus {
                hasPendingStatusChange = true
            }
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

        defer { publishStatusChange() }
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

        defer { publishStatusChange() }
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

        defer { publishStatusChange() }
        try ledger.save(modelContext)
        try reloadIfChanged(modelContext: modelContext)
        return true
    }

    /// Advances `statusRevision` for a change that can move a played-state
    /// answer, folding in any change a suppressed save left pending.
    private func publishStatusChange(_ changesStatus: Bool = true) {
        guard changesStatus || hasPendingStatusChange else {
            return
        }
        hasPendingStatusChange = false
        statusRevision &+= 1
    }

    private static func changesStatus(
        _ existing: EpisodeProgressRecord,
        position: TimeInterval,
        duration: TimeInterval?,
        isPlayed: Bool
    ) -> Bool {
        guard let previous = statusInputs(
            position: existing.position,
            duration: existing.duration,
            isPlayed: existing.isPlayed
        ),
            let updated = statusInputs(position: position, duration: duration, isPlayed: isPlayed)
        else {
            return true
        }
        return previous != updated
    }

    /// What `LibraryStore.progressSummary` feeds the played-state filters
    /// from a row: completed, and a position of at least a second. Nil when
    /// the row has no duration, because the summary then falls back to the
    /// episode's own duration, which this writer cannot see.
    private static func statusInputs(
        position: TimeInterval,
        duration: TimeInterval?,
        isPlayed: Bool
    ) -> (isCompleted: Bool, hasPosition: Bool)? {
        guard let duration else {
            return nil
        }
        let validDuration = sanitizedDuration(duration)
        let validPosition = sanitizedPosition(position, duration: validDuration)
        return (
            isCompleted: isPlayed || EpisodeProgressRules.isPlayed(position: validPosition, duration: validDuration),
            hasPosition: validPosition >= 1
        )
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
