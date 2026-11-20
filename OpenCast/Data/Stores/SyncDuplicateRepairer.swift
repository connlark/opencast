import Foundation
import OpenCastCore
import SwiftData

enum SyncDuplicateRepairer {
    /// A device offline longer than this can resurrect what a tombstone killed; repeating the
    /// delete still converges, so no per-device sync watermark is needed.
    static let tombstoneRetentionPeriod: TimeInterval = 180 * 24 * 60 * 60

    static func repair(
        modelContext: ModelContext,
        claimedFeedURLsByEpisodeID: [String: String] = [:],
        now: Date = .now,
        save: (ModelContext) throws -> Void
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
        try PlaylistSyncRepairer.repair(modelContext: modelContext, now: now, result: &result)
        collectSpentTombstones(tombstones, index: index, now: now, modelContext: modelContext, result: &result)

        if result.hasChanges {
            try save(modelContext)
        }

        return result
    }

    // MARK: - Tombstones

    private struct TombstoneIndex {
        var subscriptionClearsByFeedURL: [String: Date] = [:]
        var progressClearsByFeedURL: [String: Date] = [:]
        // Episode ID alone: fallback episode IDs are shared across raw feed-URL variants of a
        // show, and the progress index unifies on it.
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
                case .playlist, .playlistItem:
                    // Reserved and never written; known so hygiene does not delete a stray one as
                    // malformed. Only the retention horizon collects them.
                    continue
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
            case .playlist, .playlistItem, nil:
                return nil
            }
        }

        func shadowsSubscription(canonicalFeedURL: String, subscribedAt: Date) -> Bool {
            guard let deletedAt = subscriptionClearsByFeedURL[canonicalFeedURL] else {
                return false
            }
            return subscribedAt.timeIntervalSinceReferenceDate <= deletedAt.timeIntervalSinceReferenceDate
        }

        func shadowsProgress(canonicalFeedURL: String, episodeID: String, updatedAt: Date) -> Bool {
            if let deletedAt = progressClearsByFeedURL[canonicalFeedURL],
               updatedAt.timeIntervalSinceReferenceDate <= deletedAt.timeIntervalSinceReferenceDate {
                return true
            }
            if let deletedAt = progressClearsByEpisodeID[episodeID],
               updatedAt.timeIntervalSinceReferenceDate <= deletedAt.timeIntervalSinceReferenceDate {
                return true
            }
            return false
        }

        private func merge(_ clears: inout [String: Date], key: String, deletedAt: Date) {
            clears[key] = max(clears[key] ?? .distantPast, deletedAt)
        }
    }

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
        let mergedSkipSettings = PodcastPlaybackSkipSettings.greatestValid(
            in: records.map {
                PodcastPlaybackSkipSettings(
                    skipIntroSeconds: $0.skipIntroSeconds,
                    skipOutroSeconds: $0.skipOutroSeconds
                )
            }
        )
        let merged = MergedSubscription(
            feedURL: canonicalFeedURL,
            title: bestTitle(in: sortedRecords),
            author: bestOptionalText(in: sortedRecords, keyPath: \.author),
            artworkURL: bestOptionalText(in: sortedRecords, keyPath: \.artworkURL),
            // Newest, not earliest: `subscribedAt` gates subscription tombstones, and a stale
            // twin's date would drag a resubscribe behind an in-flight tombstone.
            subscribedAt: records.map(\.subscribedAt).max() ?? sortedRecords[0].subscribedAt,
            lastRefreshAt: records.compactMap(\.lastRefreshAt).max(),
            isArchived: records.allSatisfy(\.isArchived),
            isVoiceBoostEnabled: records.allSatisfy(\.isVoiceBoostEnabled),
            // Auto-detect defaults off, so an explicit opt-in on any duplicate wins.
            isAdAutoDetectEnabled: records.contains(where: \.isAdAutoDetectEnabled),
            isTranscriptAnalysisEnabled: records.contains(where: \.isTranscriptAnalysisEnabled),
            skipIntroSeconds: mergedSkipSettings.skipIntroSeconds,
            skipOutroSeconds: mergedSkipSettings.skipOutroSeconds,
            // Order-independent merges, so every peer merges the group to the same value.
            playbackRate: PodcastPlaybackRateOverride.merged(records.map(\.playbackRate)),
            autoAddToUpNext: UpNextAutoAddPosition.merged(records.map(\.autoAddToUpNext))
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
            setIfChanged(keep, \.isTranscriptAnalysisEnabled, merged.isTranscriptAnalysisEnabled)
            setIfChanged(keep, \.skipIntroSeconds, merged.skipIntroSeconds)
            setIfChanged(keep, \.skipOutroSeconds, merged.skipOutroSeconds)
            setIfChanged(keep, \.playbackRate, merged.playbackRate)
            setIfChanged(keep, \.autoAddToUpNext, merged.autoAddToUpNext)

            for record in records where record !== keep {
                modelContext.delete(record)
            }
        } else {
            // Without dedupe identities peers could pick opposite survivors and cross-delete
            // both, so one freshly identified record replaces the group; if another peer does
            // the same, the next pass converges on the smaller UUID.
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
                    isAdAutoDetectEnabled: merged.isAdAutoDetectEnabled,
                    isTranscriptAnalysisEnabled: merged.isTranscriptAnalysisEnabled,
                    skipIntroSeconds: merged.skipIntroSeconds,
                    skipOutroSeconds: merged.skipOutroSeconds,
                    playbackRate: merged.playbackRate,
                    autoAddToUpNext: merged.autoAddToUpNext
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
            // Re-key before the tombstone check: a row under a raw feed-URL variant would
            // otherwise dodge every feed-scoped delete, tombstone and duplicate group.
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

    static func mergeProgressGroup(
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
            setIfChanged(keep, \.archivedAt, best.archivedAt)
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
                    archivedAt: best.archivedAt,
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

    /// The survivor must depend only on synced immutable identity, never on content: peers can
    /// transiently see different field values and would cross-delete each other's picks.
    static func deterministicWinner<Record: AnyObject>(
        in records: [Record]
    ) -> Record? where Record: DedupeIdentified {
        records
            .filter { !$0.dedupeUUID.isEmpty }
            .min { $0.dedupeUUID < $1.dedupeUUID }
    }

    static func setIfChanged<Record: AnyObject, Value: Equatable>(
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
        var isTranscriptAnalysisEnabled: Bool
        var skipIntroSeconds: Double
        var skipOutroSeconds: Double
        var playbackRate: Double
        var autoAddToUpNext: Int
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

        if candidate.position != current.position {
            return candidate.position > current.position
        }

        return EpisodeProgressIndex.winsFinalTie(candidate, over: current)
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

    struct EpisodeKey: Hashable {
        let canonicalFeedURL: String
        let episodeID: String
    }
}

protocol DedupeIdentified {
    var dedupeUUID: String { get }
}

extension SubscriptionRecord: DedupeIdentified {}
extension EpisodeProgressRecord: DedupeIdentified {}
extension PlaylistRecord: DedupeIdentified {}
extension PlaylistItemRecord: DedupeIdentified {}
