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
        let membershipChanged = rebuilt.count != latestByEpisodeID.count
            || rebuilt.contains { episodeID, record in latestByEpisodeID[episodeID] !== record }
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
        if lhs.duration != rhs.duration {
            return (lhs.duration ?? 0) < (rhs.duration ?? 0)
        }
        return !lhs.isPlayed && rhs.isPlayed
    }
}
