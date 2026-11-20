import Foundation
import SwiftData

/// Mutations return whether an episode's indexed record changed identity; rows observe their
/// SwiftData model, so a same-instance refresh owes no revision bump.
struct EpisodeProgressIndex {
    private(set) var records: [EpisodeProgressRecord] = []
    private var latestByEpisodeID: [String: EpisodeProgressRecord] = [:]

    func latest(for episodeID: String) -> EpisodeProgressRecord? {
        latestByEpisodeID[episodeID]
    }

    /// `newRecords` must be in `allRecordsDescriptor` order.
    mutating func replaceAll(_ newRecords: [EpisodeProgressRecord]) -> Bool {
        records = newRecords
        return rebuildLatestByEpisodeID()
    }

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

    static func archivedEpisodeIDs(in records: [EpisodeProgressRecord]) -> Set<String> {
        archivedEpisodeIDs(amongLatest: latestRecordsByEpisodeID(records))
    }

    static func archivedEpisodeIDs(
        amongLatest latestRecordByEpisodeID: [String: EpisodeProgressRecord]
    ) -> Set<String> {
        var archivedEpisodeIDs: Set<String> = []
        for (episodeID, record) in latestRecordByEpisodeID where record.archivedAt != nil {
            archivedEpisodeIDs.insert(episodeID)
        }
        return archivedEpisodeIDs
    }

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

    /// Must sort exactly as `allRecordsDescriptor` does, a nil duration first: `apply` inserts
    /// a record where the next refetch would put it.
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
        // A missing duration counts as zero. Compared as optionals, nil and 0 differ while
        // neither orders first, which would leave the pick to fetch order.
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

    /// Depends only on synced fields, so every peer keeps the same copy whatever order it
    /// fetched the copies in.
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
