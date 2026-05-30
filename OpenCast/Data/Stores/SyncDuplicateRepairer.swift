import Foundation
import OpenCastCore
import SwiftData

enum SyncDuplicateRepairer {
    static func repair(modelContext: ModelContext) throws -> SyncRepairResult {
        var result = SyncRepairResult()

        try repairSubscriptions(modelContext: modelContext, result: &result)
        try repairProgressRecords(modelContext: modelContext, result: &result)

        if result.hasIssues {
            try modelContext.save()
        }

        return result
    }

    private static func repairSubscriptions(
        modelContext: ModelContext,
        result: inout SyncRepairResult
    ) throws {
        let records = try modelContext.fetch(FetchDescriptor<SubscriptionRecord>())
        let groups = Dictionary(grouping: records) { record in
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
        let keep = sortedRecords[0]

        keep.feedURL = canonicalFeedURL
        keep.isArchived = records.allSatisfy(\.isArchived)
        keep.subscribedAt = records.map(\.subscribedAt).min() ?? keep.subscribedAt
        keep.lastRefreshAt = records.compactMap(\.lastRefreshAt).max()
        keep.title = bestTitle(in: sortedRecords)
        keep.author = bestOptionalText(in: sortedRecords, keyPath: \.author)
        keep.artworkURL = bestOptionalText(in: sortedRecords, keyPath: \.artworkURL)
        keep.isVoiceBoostEnabled = records.allSatisfy(\.isVoiceBoostEnabled)

        for record in records where record !== keep {
            modelContext.delete(record)
        }

        result.duplicateSubscriptionRecordsFound += records.count - 1
        result.subscriptionGroupsMerged += 1
        result.subscriptionRecordsDeleted += records.count - 1
    }

    private static func repairProgressRecords(
        modelContext: ModelContext,
        result: inout SyncRepairResult
    ) throws {
        let records = try modelContext.fetch(FetchDescriptor<EpisodeProgressRecord>())
        let groups = Dictionary(grouping: records) { record in
            ProgressKey(
                canonicalFeedURL: URLCanonicalizer.canonicalString(forRawString: record.podcastID),
                episodeID: record.episodeID
            )
        }

        for (key, records) in groups where records.count > 1 {
            mergeProgressGroup(
                records,
                canonicalFeedURL: key.canonicalFeedURL,
                modelContext: modelContext,
                result: &result
            )
        }
    }

    private static func mergeProgressGroup(
        _ records: [EpisodeProgressRecord],
        canonicalFeedURL: String,
        modelContext: ModelContext,
        result: inout SyncRepairResult
    ) {
        let winner = bestProgress(in: records)
        let keep = winner

        keep.podcastID = canonicalFeedURL
        keep.position = winner.position.isFinite ? max(0, winner.position) : 0
        keep.duration = greatestDuration(in: records) ?? winner.duration
        keep.isPlayed = winner.isPlayed
        keep.updatedAt = winner.updatedAt

        for record in records where record !== keep {
            modelContext.delete(record)
        }

        result.duplicateProgressRecordsFound += records.count - 1
        result.progressGroupsMerged += 1
        result.progressRecordsDeleted += records.count - 1
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
        if candidate.isPlayed != current.isPlayed {
            return candidate.isPlayed
        }

        if candidate.updatedAt != current.updatedAt {
            return candidate.updatedAt > current.updatedAt
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

    private struct ProgressKey: Hashable {
        let canonicalFeedURL: String
        let episodeID: String
    }
}
