import Foundation
import OpenCastCore
import SwiftData

/// Repairs the CloudKit-synced store after imports: enforces deletion
/// tombstones, merges logical duplicates, and garbage-collects spent
/// tombstones. Winner selection follows Apple's CloudKit dedupe pattern —
/// the copy with the smallest synced `dedupeUUID` survives, so every device
/// independently keeps the same record instead of cross-deleting each
/// other's picks. The synced models have no relationships, so losing copies
/// are hard-deleted.
enum SyncDuplicateRepairer {
    /// Tombstones older than this are garbage collected. A device offline
    /// longer than the horizon can resurrect records the tombstone would have
    /// killed; repeating the delete still converges, so a long horizon is
    /// enough without tracking per-device sync watermarks.
    static let tombstoneRetentionPeriod: TimeInterval = 180 * 24 * 60 * 60

    static func repair(
        modelContext: ModelContext,
        claimedFeedURLsByEpisodeID: [String: String] = [:],
        now: Date = .now
    ) throws -> SyncRepairResult {
        var result = SyncRepairResult()

        let tombstones = try modelContext.fetch(FetchDescriptor<SyncTombstoneRecord>())
        let index = TombstoneIndex(tombstones)

        try repairSubscriptions(modelContext: modelContext, tombstones: index, result: &result)
        try repairProgressRecords(
            modelContext: modelContext,
            tombstones: index,
            claimedFeedURLsByEpisodeID: claimedFeedURLsByEpisodeID,
            result: &result
        )
        collectSpentTombstones(tombstones, index: index, now: now, modelContext: modelContext, result: &result)

        if result.hasChanges {
            try modelContext.save()
        }

        return result
    }

    // MARK: - Tombstones

    /// Per-key latest deletion instants, keyed by canonical identifiers so
    /// records with drifted raw URLs still match.
    private struct TombstoneIndex {
        var subscriptionClearsByFeedURL: [String: Date] = [:]
        var progressClearsByFeedURL: [String: Date] = [:]
        // Keyed by episode ID alone: episode identity can come from fallback
        // hashes (audio URL, title+date) that are shared across raw feed-URL
        // variants of the same show, and the progress index unifies on it.
        var progressClearsByEpisodeID: [String: Date] = [:]

        init(_ tombstones: [SyncTombstoneRecord]) {
            for tombstone in tombstones {
                let feedURL = URLCanonicalizer.canonicalString(forRawString: tombstone.feedURL)
                switch SyncTombstoneScope(rawValue: tombstone.scope) {
                case .subscription:
                    merge(&subscriptionClearsByFeedURL, key: feedURL, deletedAt: tombstone.deletedAt)
                case .feedProgress:
                    merge(&progressClearsByFeedURL, key: feedURL, deletedAt: tombstone.deletedAt)
                case .episodeProgress:
                    guard let episodeID = tombstone.episodeID else {
                        continue
                    }
                    merge(&progressClearsByEpisodeID, key: episodeID, deletedAt: tombstone.deletedAt)
                case nil:
                    continue
                }
            }
        }

        func latestClear(for tombstone: SyncTombstoneRecord) -> Date? {
            let feedURL = URLCanonicalizer.canonicalString(forRawString: tombstone.feedURL)
            switch SyncTombstoneScope(rawValue: tombstone.scope) {
            case .subscription:
                return subscriptionClearsByFeedURL[feedURL]
            case .feedProgress:
                return progressClearsByFeedURL[feedURL]
            case .episodeProgress:
                guard let episodeID = tombstone.episodeID else {
                    return nil
                }
                return progressClearsByEpisodeID[episodeID]
            case nil:
                return nil
            }
        }

        func shadowsSubscription(canonicalFeedURL: String, subscribedAt: Date) -> Bool {
            guard let deletedAt = subscriptionClearsByFeedURL[canonicalFeedURL] else {
                return false
            }
            return subscribedAt <= deletedAt
        }

        func shadowsProgress(canonicalFeedURL: String, episodeID: String, updatedAt: Date) -> Bool {
            if let deletedAt = progressClearsByFeedURL[canonicalFeedURL], updatedAt <= deletedAt {
                return true
            }
            if let deletedAt = progressClearsByEpisodeID[episodeID], updatedAt <= deletedAt {
                return true
            }
            return false
        }

        private func merge(_ clears: inout [String: Date], key: String, deletedAt: Date) {
            clears[key] = max(clears[key] ?? .distantPast, deletedAt)
        }
    }

    /// Deletes tombstones that no longer protect anything: ones superseded by
    /// a newer tombstone with the same scope and key, and ones past the
    /// retention horizon.
    private static func collectSpentTombstones(
        _ tombstones: [SyncTombstoneRecord],
        index: TombstoneIndex,
        now: Date,
        modelContext: ModelContext,
        result: inout SyncRepairResult
    ) {
        for tombstone in tombstones {
            let isSuperseded = (index.latestClear(for: tombstone) ?? tombstone.deletedAt) > tombstone.deletedAt
            let isExpired = now.timeIntervalSince(tombstone.deletedAt) > tombstoneRetentionPeriod
            let isMalformed = SyncTombstoneScope(rawValue: tombstone.scope) == nil
                || (tombstone.scope == SyncTombstoneScope.episodeProgress.rawValue && tombstone.episodeID == nil)
            if isSuperseded || isExpired || isMalformed {
                modelContext.delete(tombstone)
                result.expiredTombstonesDeleted += 1
            }
        }
    }

    // MARK: - Subscriptions

    private static func repairSubscriptions(
        modelContext: ModelContext,
        tombstones: TombstoneIndex,
        result: inout SyncRepairResult
    ) throws {
        let records = try modelContext.fetch(FetchDescriptor<SubscriptionRecord>())
        var survivors: [SubscriptionRecord] = []
        survivors.reserveCapacity(records.count)
        for record in records {
            let canonicalFeedURL = URLCanonicalizer.canonicalString(forRawString: record.feedURL)
            if tombstones.shadowsSubscription(
                canonicalFeedURL: canonicalFeedURL,
                subscribedAt: record.subscribedAt
            ) {
                modelContext.delete(record)
                result.tombstonedSubscriptionRecordsDeleted += 1
            } else {
                survivors.append(record)
            }
        }

        let groups = Dictionary(grouping: survivors) { record in
            URLCanonicalizer.canonicalString(forRawString: record.feedURL)
        }

        for (canonicalFeedURL, records) in groups where records.count > 1 {
            mergeSubscriptionGroup(
                records,
                canonicalFeedURL: canonicalFeedURL,
                modelContext: modelContext,
                result: &result
            )
        }
    }

    private static func mergeSubscriptionGroup(
        _ records: [SubscriptionRecord],
        canonicalFeedURL: String,
        modelContext: ModelContext,
        result: inout SyncRepairResult
    ) {
        let sortedRecords = records.sorted(by: isBetterSubscription)
        let merged = MergedSubscription(
            feedURL: canonicalFeedURL,
            title: bestTitle(in: sortedRecords),
            author: bestOptionalText(in: sortedRecords, keyPath: \.author),
            artworkURL: bestOptionalText(in: sortedRecords, keyPath: \.artworkURL),
            // Newest, not earliest: `subscribedAt` gates subscription
            // tombstones, and a merge that inherited a stale twin's old date
            // would drag a legitimate resubscribe behind an in-flight
            // tombstone and get it killed.
            subscribedAt: records.map(\.subscribedAt).max() ?? sortedRecords[0].subscribedAt,
            lastRefreshAt: records.compactMap(\.lastRefreshAt).max(),
            isArchived: records.allSatisfy(\.isArchived),
            isVoiceBoostEnabled: records.allSatisfy(\.isVoiceBoostEnabled),
            // Auto-detect defaults off, so an explicit opt-in on any duplicate wins.
            isAdAutoDetectEnabled: records.contains(where: \.isAdAutoDetectEnabled)
        )

        if let keep = deterministicWinner(in: records) {
            setIfChanged(keep, \.feedURL, merged.feedURL)
            setIfChanged(keep, \.title, merged.title)
            setIfChanged(keep, \.author, merged.author)
            setIfChanged(keep, \.artworkURL, merged.artworkURL)
            setIfChanged(keep, \.subscribedAt, merged.subscribedAt)
            setIfChanged(keep, \.lastRefreshAt, merged.lastRefreshAt)
            setIfChanged(keep, \.isArchived, merged.isArchived)
            setIfChanged(keep, \.isVoiceBoostEnabled, merged.isVoiceBoostEnabled)
            setIfChanged(keep, \.isAdAutoDetectEnabled, merged.isAdAutoDetectEnabled)

            for record in records where record !== keep {
                modelContext.delete(record)
            }
        } else {
            // Legacy copies without dedupe identities: peers could pick
            // opposite survivors and cross-delete both. Replace the whole
            // group with one freshly identified record; if another peer
            // inserts its own replacement, the next pass converges on the
            // smaller UUID.
            modelContext.insert(
                SubscriptionRecord(
                    feedURL: merged.feedURL,
                    title: merged.title,
                    author: merged.author,
                    artworkURL: merged.artworkURL,
                    subscribedAt: merged.subscribedAt,
                    lastRefreshAt: merged.lastRefreshAt,
                    isArchived: merged.isArchived,
                    isVoiceBoostEnabled: merged.isVoiceBoostEnabled,
                    isAdAutoDetectEnabled: merged.isAdAutoDetectEnabled
                )
            )
            for record in records {
                modelContext.delete(record)
            }
        }

        result.duplicateSubscriptionRecordsFound += records.count - 1
        result.subscriptionGroupsMerged += 1
        result.subscriptionRecordsDeleted += records.count - 1
    }

    // MARK: - Progress

    private static func repairProgressRecords(
        modelContext: ModelContext,
        tombstones: TombstoneIndex,
        claimedFeedURLsByEpisodeID: [String: String],
        result: inout SyncRepairResult
    ) throws {
        let records = try modelContext.fetch(FetchDescriptor<EpisodeProgressRecord>())
        var survivors: [EpisodeProgressRecord] = []
        survivors.reserveCapacity(records.count)
        for record in records {
            // Re-key variant records first: a progress row written under a
            // raw feed-URL variant (http vs https, bare host) of the show
            // that unambiguously claims its episode would otherwise dodge
            // every feed-scoped delete, tombstone, and duplicate group while
            // still surfacing through the episode-keyed progress index.
            var canonicalFeedURL = URLCanonicalizer.canonicalString(forRawString: record.podcastID)
            if let claimedFeedURL = claimedFeedURLsByEpisodeID[record.episodeID],
               claimedFeedURL != canonicalFeedURL {
                record.podcastID = claimedFeedURL
                canonicalFeedURL = claimedFeedURL
                result.normalizedProgressRecords += 1
            }
            if tombstones.shadowsProgress(
                canonicalFeedURL: canonicalFeedURL,
                episodeID: record.episodeID,
                updatedAt: record.updatedAt
            ) {
                modelContext.delete(record)
                result.tombstonedProgressRecordsDeleted += 1
            } else {
                survivors.append(record)
            }
        }

        let groups = Dictionary(grouping: survivors) { record in
            EpisodeKey(
                canonicalFeedURL: URLCanonicalizer.canonicalString(forRawString: record.podcastID),
                episodeID: record.episodeID
            )
        }

        for (key, records) in groups where records.count > 1 {
            mergeProgressGroup(
                records,
                key: key,
                modelContext: modelContext,
                result: &result
            )
        }
    }

    private static func mergeProgressGroup(
        _ records: [EpisodeProgressRecord],
        key: EpisodeKey,
        modelContext: ModelContext,
        result: inout SyncRepairResult
    ) {
        let best = bestProgress(in: records)
        let mergedPosition = best.position.isFinite ? max(0, best.position) : 0
        let mergedDuration = greatestDuration(in: records) ?? best.duration

        if let keep = deterministicWinner(in: records) {
            setIfChanged(keep, \.podcastID, key.canonicalFeedURL)
            setIfChanged(keep, \.position, mergedPosition)
            setIfChanged(keep, \.duration, mergedDuration)
            setIfChanged(keep, \.isPlayed, best.isPlayed)
            setIfChanged(keep, \.updatedAt, best.updatedAt)

            for record in records where record !== keep {
                modelContext.delete(record)
            }
        } else {
            modelContext.insert(
                EpisodeProgressRecord(
                    episodeID: key.episodeID,
                    podcastID: key.canonicalFeedURL,
                    position: mergedPosition,
                    duration: mergedDuration,
                    isPlayed: best.isPlayed,
                    updatedAt: best.updatedAt
                )
            )
            for record in records {
                modelContext.delete(record)
            }
        }

        result.duplicateProgressRecordsFound += records.count - 1
        result.progressGroupsMerged += 1
        result.progressRecordsDeleted += records.count - 1
    }

    // MARK: - Winner selection and merge helpers

    /// The surviving copy must be a pure function of synced immutable
    /// identity, never of mutable content: peers can transiently see
    /// different field values for the same records and would cross-delete
    /// each other's content-based picks. Returns nil when no copy carries an
    /// identity (all predate the field).
    private static func deterministicWinner<Record: AnyObject>(
        in records: [Record]
    ) -> Record? where Record: DedupeIdentified {
        records
            .filter { !$0.dedupeUUID.isEmpty }
            .min { $0.dedupeUUID < $1.dedupeUUID }
    }

    private static func setIfChanged<Record: AnyObject, Value: Equatable>(
        _ record: Record,
        _ keyPath: ReferenceWritableKeyPath<Record, Value>,
        _ value: Value
    ) {
        if record[keyPath: keyPath] != value {
            record[keyPath: keyPath] = value
        }
    }

    private struct MergedSubscription {
        var feedURL: String
        var title: String
        var author: String?
        var artworkURL: String?
        var subscribedAt: Date
        var lastRefreshAt: Date?
        var isArchived: Bool
        var isVoiceBoostEnabled: Bool
        var isAdAutoDetectEnabled: Bool
    }

    private static func isBetterSubscription(
        _ candidate: SubscriptionRecord,
        than current: SubscriptionRecord
    ) -> Bool {
        if candidate.isArchived != current.isArchived {
            return !candidate.isArchived
        }

        switch (candidate.lastRefreshAt, current.lastRefreshAt) {
        case let (candidateDate?, currentDate?) where candidateDate != currentDate:
            return candidateDate > currentDate
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        default:
            break
        }

        let candidateMetadataScore = metadataScore(for: candidate)
        let currentMetadataScore = metadataScore(for: current)
        if candidateMetadataScore != currentMetadataScore {
            return candidateMetadataScore > currentMetadataScore
        }

        if candidate.subscribedAt != current.subscribedAt {
            return candidate.subscribedAt > current.subscribedAt
        }

        return candidate.feedURL < current.feedURL
    }

    private static func bestProgress(in records: [EpisodeProgressRecord]) -> EpisodeProgressRecord {
        records.max { current, candidate in
            isBetterProgress(candidate, than: current)
        } ?? records[0]
    }

    private static func isBetterProgress(
        _ candidate: EpisodeProgressRecord,
        than current: EpisodeProgressRecord
    ) -> Bool {
        if candidate.updatedAt != current.updatedAt {
            return candidate.updatedAt > current.updatedAt
        }

        if candidate.isPlayed != current.isPlayed {
            return candidate.isPlayed
        }

        let candidateDuration = candidate.duration ?? 0
        let currentDuration = current.duration ?? 0
        if candidateDuration != currentDuration {
            return candidateDuration > currentDuration
        }

        return candidate.position > current.position
    }

    private static func metadataScore(for record: SubscriptionRecord) -> Int {
        [
            record.title.trimmedNonEmpty,
            record.author?.trimmedNonEmpty,
            record.artworkURL?.trimmedNonEmpty
        ]
        .count(where: { $0 != nil })
    }

    private static func bestTitle(in sortedRecords: [SubscriptionRecord]) -> String {
        sortedRecords.compactMap { $0.title.trimmedNonEmpty }.first ?? ""
    }

    private static func bestOptionalText(
        in sortedRecords: [SubscriptionRecord],
        keyPath: KeyPath<SubscriptionRecord, String?>
    ) -> String? {
        sortedRecords.compactMap { $0[keyPath: keyPath]?.trimmedNonEmpty }.first
    }

    private static func greatestDuration(in records: [EpisodeProgressRecord]) -> Double? {
        records
            .compactMap(\.duration)
            .filter { $0.isFinite && $0 > 0 }
            .max()
    }

    private struct EpisodeKey: Hashable {
        let canonicalFeedURL: String
        let episodeID: String
    }
}

/// Shared shape for `deterministicWinner`; both synced record models carry a
/// stable dedupe identity.
protocol DedupeIdentified {
    var dedupeUUID: String { get }
}

extension SubscriptionRecord: DedupeIdentified {}
extension EpisodeProgressRecord: DedupeIdentified {}
