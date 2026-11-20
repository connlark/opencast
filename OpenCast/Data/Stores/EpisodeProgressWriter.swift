import Foundation
import Observation
import OpenCastCore
import SwiftData

@Observable
final class EpisodeProgressWriter {
    /// Moves only on index membership changes and reloads; rows observe their SwiftData model.
    private(set) var revision = 0
    /// Moves on any write that can change a played-state filter's input, in-place edits included,
    /// but not on a position-only flush, so listening does not re-evaluate every list. A failed
    /// save still moves it: the live row keeps the edit.
    private(set) var statusRevision = 0
    /// Archiving edits a row in place, which moves neither revision. Every reload rebuilds this
    /// set, changed rows or not: an import refreshes live rows without an Observation notification.
    private(set) var archivedEpisodeIDs: Set<String> = []
    /// A suppressed save's status change: the next write compares against the already-updated
    /// row, so it cannot see the change on its own.
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

    func reload(modelContext: ModelContext) throws {
        let fetchedRecords = try modelContext.fetch(EpisodeProgressIndex.allRecordsDescriptor())
        replaceAll(fetchedRecords)
        publishArchivedEpisodeIDs(EpisodeProgressIndex.archivedEpisodeIDs(in: fetchedRecords))
        publishStatusChange(false)
    }

    /// Compares the latest rows too: an import edits live rows in place, so they can compare
    /// unchanged while the edit makes another copy of an episode its latest.
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

    /// Returns false, without saving, when nothing meaningful changed. With
    /// `refreshObservableProgress: false` the projection waits for the next `reloadIfChanged`.
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

    func setArchived(
        _ isArchived: Bool,
        episodeID: String,
        podcastID: String,
        modelContext: ModelContext
    ) throws -> Bool {
        try setArchived(isArchived, episodeIDs: [episodeID], podcastID: podcastID, modelContext: modelContext)
    }

    /// Edits the row the index would choose among every copy of the episode, raw feed-URL variants
    /// included, so later listening keeps the archive. `updatedAt` moves so duplicate repair and
    /// tombstones order the archive like any other write.
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
            // An import not yet reloaded can have made another, archived copy the latest.
            publishLatestRecords(of: episodeIDs, in: latestRecordByEpisodeID)
            return false
        }

        defer { publishStatusChange(false) }
        do {
            try ledger.save(modelContext)
        } catch {
            // The context is shared: a row left dirty would ride out uncredited with another
            // writer's save, and a context-wide rollback would discard that writer's changes.
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

    /// An archived subscription still marks its show as kept.
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

    /// Deletes copies under every feed-URL variant: the tombstone shadows by episode ID alone, and
    /// a copy left behind would become the latest row and bring back its archive or listening.
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

    /// Must match what `LibraryStore.progressSummary` feeds the played-state filters. Nil without
    /// a duration: the summary then uses the episode's own, which this writer cannot see.
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

    private static var latestFirstSortDescriptors: [SortDescriptor<EpisodeProgressRecord>] {
        [
            SortDescriptor(\.updatedAt, order: .reverse),
            SortDescriptor(\.position, order: .reverse),
            SortDescriptor(\.duration, order: .reverse)
        ]
    }
}
