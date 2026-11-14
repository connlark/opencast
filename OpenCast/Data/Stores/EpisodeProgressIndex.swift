import Foundation
import SwiftData

/// LibraryStore's in-memory projection of the synced progress table: the
/// store-ordered record array plus the latest-record-per-episode map behind
/// O(1) progress lookups. The fetch descriptor and the in-memory comparator
/// live together here because `apply` relies on their sort keys agreeing —
/// an inserted record must land exactly where the next refetch would put it.
///
/// The index only projects; every save, self-save credit, and the
/// observation revision stay with EpisodeProgressWriter. Mutations return whether an
/// episode's indexed record changed identity — the revision-bump condition;
/// rows observe their SwiftData model directly, so same-instance refreshes
/// owe no bump.
struct EpisodeProgressIndex {
    private(set) var records: [EpisodeProgressRecord] = []
    private var latestByEpisodeID: [String: EpisodeProgressRecord] = [:]

    func latest(for episodeID: String) -> EpisodeProgressRecord? {
        latestByEpisodeID[episodeID]
    }

    /// Replaces the full record set (store-ordered, from
    /// `allRecordsDescriptor`); returns whether any episode's indexed record
    /// changed identity.
    mutating func replaceAll(_ newRecords: [EpisodeProgressRecord]) -> Bool {
        records = newRecords
        return rebuildLatestByEpisodeID()
    }

    /// Re-seats one updated or inserted record in store order and indexes it
    /// as its episode's latest; returns whether the indexed record changed
    /// identity.
    mutating func apply(_ record: EpisodeProgressRecord) -> Bool {
        if let existingIndex = records.firstIndex(where: { $0 === record }) {
            records.remove(at: existingIndex)
        }
        insertInOrder(record)

        let indexedRecord = latestByEpisodeID[record.episodeID]
        latestByEpisodeID[record.episodeID] = record
        return indexedRecord !== record
    }

    static func allRecordsDescriptor() -> FetchDescriptor<EpisodeProgressRecord> {
        FetchDescriptor<EpisodeProgressRecord>(
            sortBy: [
                SortDescriptor(\.podcastID),
                SortDescriptor(\.episodeID),
                SortDescriptor(\.updatedAt),
                SortDescriptor(\.position),
                SortDescriptor(\.duration)
            ]
        )
    }

    static func latestRecordsByEpisodeID(
        _ records: [EpisodeProgressRecord]
    ) -> [String: EpisodeProgressRecord] {
        var latestRecordByEpisodeID: [String: EpisodeProgressRecord] = [:]
        latestRecordByEpisodeID.reserveCapacity(records.count)
        for record in records {
            if let existing = latestRecordByEpisodeID[record.episodeID] {
                guard record.updatedAt > existing.updatedAt || (
                    record.updatedAt == existing.updatedAt
                        && precedesForIndex(record, existing)
                ) else {
                    continue
                }
            }
            latestRecordByEpisodeID[record.episodeID] = record
        }
        return latestRecordByEpisodeID
    }

    /// The episodes whose latest record, by the rule of
    /// `latestRecordsByEpisodeID`, carries an archive.
    static func archivedEpisodeIDs(in records: [EpisodeProgressRecord]) -> Set<String> {
        archivedEpisodeIDs(amongLatest: latestRecordsByEpisodeID(records))
    }

    /// The archived episodes of a `latestRecordsByEpisodeID` result.
    static func archivedEpisodeIDs(
        amongLatest latestRecordByEpisodeID: [String: EpisodeProgressRecord]
    ) -> Set<String> {
        var archivedEpisodeIDs: Set<String> = []
        for (episodeID, record) in latestRecordByEpisodeID where record.archivedAt != nil {
            archivedEpisodeIDs.insert(episodeID)
        }
        return archivedEpisodeIDs
    }

    /// Whether every episode's indexed record is the one `latest` names, and
    /// no other episode is indexed.
    func indexesLatest(_ latest: [String: EpisodeProgressRecord]) -> Bool {
        latest.count == latestByEpisodeID.count
            && latest.allSatisfy { episodeID, record in latestByEpisodeID[episodeID] === record }
    }

    static func records(
        _ lhs: [EpisodeProgressRecord],
        match rhs: [EpisodeProgressRecord]
    ) -> Bool {
        guard lhs.count == rhs.count else {
            return false
        }

        for (lhsRecord, rhsRecord) in zip(lhs, rhs) {
            guard lhsRecord.episodeID == rhsRecord.episodeID,
                  lhsRecord.podcastID == rhsRecord.podcastID,
                  lhsRecord.position == rhsRecord.position,
                  lhsRecord.duration == rhsRecord.duration,
                  lhsRecord.isPlayed == rhsRecord.isPlayed,
                  lhsRecord.updatedAt == rhsRecord.updatedAt
            else {
                return false
            }
        }

        return true
    }

    private mutating func rebuildLatestByEpisodeID() -> Bool {
        let rebuilt = Self.latestRecordsByEpisodeID(records)
        let membershipChanged = !indexesLatest(rebuilt)
        latestByEpisodeID = rebuilt
        return membershipChanged
    }

    private mutating func insertInOrder(_ record: EpisodeProgressRecord) {
        var lowerBound = records.startIndex
        var upperBound = records.endIndex
        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            if Self.precedesInStore(records[middle], record) {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        records.insert(record, at: lowerBound)
    }

    /// Mirrors `allRecordsDescriptor`'s sort keys, including nil durations
    /// ordering before non-nil.
    private static func precedesInStore(
        _ lhs: EpisodeProgressRecord,
        _ rhs: EpisodeProgressRecord
    ) -> Bool {
        if lhs.podcastID != rhs.podcastID {
            return lhs.podcastID < rhs.podcastID
        }
        if lhs.episodeID != rhs.episodeID {
            return lhs.episodeID < rhs.episodeID
        }
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt < rhs.updatedAt
        }
        if lhs.position != rhs.position {
            return lhs.position < rhs.position
        }
        switch (lhs.duration, rhs.duration) {
        case (nil, nil):
            return false
        case (nil, .some):
            return true
        case (.some, nil):
            return false
        case let (lhsDuration?, rhsDuration?):
            return lhsDuration < rhsDuration
        }
    }

    /// Deterministic same-instant tie-break for the latest-per-episode index.
    private static func precedesForIndex(
        _ lhs: EpisodeProgressRecord,
        _ rhs: EpisodeProgressRecord
    ) -> Bool {
        if lhs.podcastID != rhs.podcastID {
            return lhs.podcastID < rhs.podcastID
        }
        if lhs.episodeID != rhs.episodeID {
            return lhs.episodeID < rhs.episodeID
        }
        if lhs.position != rhs.position {
            return lhs.position < rhs.position
        }
        // A missing duration counts as zero, as repair reads it. Compared as
        // optionals, nil and 0 differ while neither orders first, which
        // would leave the pick to fetch order.
        let lhsDuration = lhs.duration ?? 0
        let rhsDuration = rhs.duration ?? 0
        if lhsDuration != rhsDuration {
            return lhsDuration < rhsDuration
        }
        if lhs.isPlayed != rhs.isPlayed {
            return !lhs.isPlayed
        }
        return winsFinalTie(lhs, over: rhs)
    }

    /// The last tie-break between two copies of an episode that agree on
    /// every listening field, shared with duplicate repair so every peer
    /// keeps the same archive whatever order it fetched the copies in: an
    /// archived copy beats an unarchived one, then the later archive, then
    /// the smaller `dedupeUUID`.
    static func winsFinalTie(_ lhs: EpisodeProgressRecord, over rhs: EpisodeProgressRecord) -> Bool {
        switch (lhs.archivedAt, rhs.archivedAt) {
        case let (lhsArchivedAt?, rhsArchivedAt?) where lhsArchivedAt != rhsArchivedAt:
            lhsArchivedAt > rhsArchivedAt
        case (.some, nil):
            true
        case (nil, .some):
            false
        default:
            lhs.dedupeUUID < rhs.dedupeUUID
        }
    }
}
