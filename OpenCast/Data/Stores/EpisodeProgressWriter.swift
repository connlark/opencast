import Foundation
import Observation
import OpenCastCore
import SwiftData

/// The synced progress table's writer and published projection: every
/// progress save (through the self-save ledger), the store-ordered record
/// array with its latest-per-episode index, the revision that rows observe
/// for index membership changes, and the archived set the Inbox reads.
/// Store-level presentation — the failed state and the error banner —
/// stays with LibraryStore: every method here throws and the store records
/// the failure.
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
    /// The episodes whose latest row carries an archive: the Inbox's
    /// membership signal. Archiving edits a row in place, which moves
    /// neither revision, so readers observe this set instead. Every reload
    /// rebuilds it from the fetched rows, changed or not, because a refetch
    /// that imports another context's edit refreshes the live rows without
    /// an Observation notification; it is assigned only when it differs.
    private(set) var archivedEpisodeIDs: Set<String> = []
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
        let fetchedRecords = try modelContext.fetch(EpisodeProgressIndex.allRecordsDescriptor())
        replaceAll(fetchedRecords)
        publishArchivedEpisodeIDs(EpisodeProgressIndex.archivedEpisodeIDs(in: fetchedRecords))
        publishStatusChange(false)
    }

    /// Refetches and republishes only when the stored rows, or the copy an
    /// episode's latest row comes from, differ from the projection; returns
    /// whether they did. The archived set is rebuilt either way.
    ///
    /// An import edits the live rows in place, so they can compare unchanged
    /// while the edit makes another copy of an episode its latest (an older
    /// copy archived on another device): the latest rows are compared too.
    @discardableResult
    func reloadIfChanged(modelContext: ModelContext) throws -> Bool {
        let fetchedRecords = try modelContext.fetch(EpisodeProgressIndex.allRecordsDescriptor())
        publishStatusChange(false)
        let latestRecordByEpisodeID = EpisodeProgressIndex.latestRecordsByEpisodeID(fetchedRecords)
        publishArchivedEpisodeIDs(EpisodeProgressIndex.archivedEpisodeIDs(amongLatest: latestRecordByEpisodeID))
        if EpisodeProgressIndex.records(index.records, match: fetchedRecords),
           index.indexesLatest(latestRecordByEpisodeID) {
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
        publishArchivedEpisodeIDs([])
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
        if refreshObservableProgress {
            if index.apply(updatedRecord) {
                revision &+= 1
            }
            publishArchivedMembership(
                of: [updatedRecord.episodeID],
                in: [updatedRecord.episodeID: updatedRecord]
            )
        }
        return true
    }

    /// Archives or unarchives one episode; see the batch form.
    func setArchived(
        _ isArchived: Bool,
        episodeID: String,
        podcastID: String,
        modelContext: ModelContext
    ) throws -> Bool {
        try setArchived(isArchived, episodeIDs: [episodeID], podcastID: podcastID, modelContext: modelContext)
    }

    /// Archives or unarchives the listed episodes in one save. Each
    /// episode's latest row is edited in place, chosen as the index chooses
    /// it among every copy of the episode (the episode ID already names the
    /// show, so a copy under a raw feed-URL variant counts), so later
    /// listening keeps the archive; archiving an episode with no row inserts
    /// one under `podcastID` with no listening. `updatedAt` moves with the
    /// archive so duplicate repair and tombstones order it like any other
    /// write. Every listed episode's fetched latest row is then indexed and
    /// its membership re-read from it, changed or not, so an import the
    /// projection has not reloaded yet (another copy archived and now the
    /// latest) reaches both the index and the set. Returns false, with no
    /// save, when no row would change.
    ///
    /// A failed save puts the edited fields back and deletes the inserted
    /// rows before rethrowing: the context is shared, so a row left dirty
    /// would make a retry a no-op and ride out with another writer's save,
    /// uncredited. Rolling the whole context back would discard those other
    /// writers' pending changes too.
    func setArchived(
        _ isArchived: Bool,
        episodeIDs: Set<String>,
        podcastID: String,
        modelContext: ModelContext
    ) throws -> Bool {
        let targetEpisodeIDs = episodeIDs
        let storedRecords = try modelContext.fetch(
            FetchDescriptor<EpisodeProgressRecord>(
                predicate: #Predicate { record in
                    targetEpisodeIDs.contains(record.episodeID)
                }
            )
        )
        var latestRecordByEpisodeID = EpisodeProgressIndex.latestRecordsByEpisodeID(storedRecords)

        let updatedAt = Date.now
        var edits: [(record: EpisodeProgressRecord, archivedAt: Date?, updatedAt: Date)] = []
        var insertedRecords: [EpisodeProgressRecord] = []
        for episodeID in episodeIDs {
            if let record = latestRecordByEpisodeID[episodeID] {
                guard (record.archivedAt != nil) != isArchived else {
                    continue
                }
                edits.append((record, record.archivedAt, record.updatedAt))
                record.archivedAt = isArchived ? updatedAt : nil
                record.updatedAt = updatedAt
            } else if isArchived {
                let record = EpisodeProgressRecord(
                    episodeID: episodeID,
                    podcastID: podcastID,
                    archivedAt: updatedAt,
                    updatedAt: updatedAt
                )
                modelContext.insert(record)
                insertedRecords.append(record)
                latestRecordByEpisodeID[episodeID] = record
            }
        }

        guard !edits.isEmpty || !insertedRecords.isEmpty else {
            publishLatestRecords(of: episodeIDs, in: latestRecordByEpisodeID)
            return false
        }

        defer { publishStatusChange(false) }
        do {
            try ledger.save(modelContext)
        } catch {
            for edit in edits {
                edit.record.archivedAt = edit.archivedAt
                edit.record.updatedAt = edit.updatedAt
            }
            for record in insertedRecords {
                modelContext.delete(record)
            }
            throw error
        }
        publishLatestRecords(of: episodeIDs, in: latestRecordByEpisodeID)
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

    /// Deletes every progress row of one episode and tombstones the episode;
    /// returns false when there was nothing to clear. The tombstone shadows
    /// by episode ID alone, so a copy under a raw feed-URL variant goes too:
    /// left behind, it would become the episode's latest row and bring back
    /// its archive or its listening until repair deleted it.
    func clear(episodeID: String, podcastID: String, modelContext: ModelContext) throws -> Bool {
        let records = try modelContext.fetch(
            FetchDescriptor<EpisodeProgressRecord>(
                predicate: #Predicate { record in
                    record.episodeID == episodeID
                }
            )
        )
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

    private func publishArchivedEpisodeIDs(_ archivedEpisodeIDs: Set<String>) {
        if archivedEpisodeIDs != self.archivedEpisodeIDs {
            self.archivedEpisodeIDs = archivedEpisodeIDs
        }
    }

    /// Indexes each listed episode's fetched latest row, then re-reads the
    /// episodes' archives from those rows. The same bump condition as
    /// `update`: `revision` moves only when an episode's indexed row changes
    /// (an inserted row, or a copy an import made the latest), not for an
    /// in-place edit of the row the index already holds.
    private func publishLatestRecords(
        of episodeIDs: Set<String>,
        in latestRecordByEpisodeID: [String: EpisodeProgressRecord]
    ) {
        var indexedIdentityChanged = false
        for episodeID in episodeIDs {
            if let record = latestRecordByEpisodeID[episodeID] {
                indexedIdentityChanged = index.apply(record) || indexedIdentityChanged
            }
        }
        if indexedIdentityChanged {
            revision &+= 1
        }
        publishArchivedMembership(of: episodeIDs, in: latestRecordByEpisodeID)
    }

    /// Re-reads each listed episode's archive from the row that is now its
    /// latest; an episode with no row is not archived.
    private func publishArchivedMembership(
        of episodeIDs: some Sequence<String>,
        in latestRecordByEpisodeID: [String: EpisodeProgressRecord]
    ) {
        var archivedEpisodeIDs = archivedEpisodeIDs
        for episodeID in episodeIDs {
            if latestRecordByEpisodeID[episodeID]?.archivedAt == nil {
                archivedEpisodeIDs.remove(episodeID)
            } else {
                archivedEpisodeIDs.insert(episodeID)
            }
        }
        publishArchivedEpisodeIDs(archivedEpisodeIDs)
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

    private static func recordsDescriptor(
        episodeID: String,
        podcastID: String
    ) -> FetchDescriptor<EpisodeProgressRecord> {
        FetchDescriptor<EpisodeProgressRecord>(
            predicate: #Predicate { record in
                record.episodeID == episodeID && record.podcastID == podcastID
            },
            sortBy: latestFirstSortDescriptors
        )
    }

    /// The order that makes an episode's first fetched row the one `update`
    /// edits.
    private static var latestFirstSortDescriptors: [SortDescriptor<EpisodeProgressRecord>] {
        [
            SortDescriptor(\.updatedAt, order: .reverse),
            SortDescriptor(\.position, order: .reverse),
            SortDescriptor(\.duration, order: .reverse)
        ]
    }
}
