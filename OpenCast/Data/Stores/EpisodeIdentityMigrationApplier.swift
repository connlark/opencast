import Foundation
import OpenCastCore
import SwiftData

/// The per-match episode-identity migration body, shared by refresh
/// reconciliation and subscription migration: re-keys progress rows,
/// device-local sidecars, and ad-free-pass queue items onto the successor
/// episode ID and tombstones the departed ID. Inserts into the passed
/// context and never saves — the caller owns the save, because tombstones
/// must land in the same save as the records they cover.
enum EpisodeIdentityMigrationApplier {
    static func apply(
        _ matches: [EpisodeIdentityReconciler.Match],
        canonicalFeedURL: String,
        sidecarMigrators: [any EpisodeIdentitySidecarMigrating],
        modelContext: ModelContext
    ) throws {
        let deletedAt = Date.now
        for match in matches {
            try migrateProgressRecords(
                from: match.departedEpisodeID,
                to: match.successorEpisodeID,
                canonicalFeedURL: canonicalFeedURL,
                modelContext: modelContext
            )
            for migrator in sidecarMigrators {
                try migrator.migrateEpisodeSidecars(
                    from: match.departedEpisodeID,
                    to: match.successorEpisodeID,
                    canonicalPodcastID: canonicalFeedURL,
                    modelContext: modelContext
                )
            }
            try migrateAdFreePassQueueItems(
                from: match.departedEpisodeID,
                to: match.successorEpisodeID,
                canonicalFeedURL: canonicalFeedURL,
                modelContext: modelContext
            )
            modelContext.insert(
                SyncTombstoneRecord(
                    scope: .episodeProgress,
                    feedURL: canonicalFeedURL,
                    episodeID: match.departedEpisodeID,
                    deletedAt: deletedAt
                )
            )
        }
    }

    private static func migrateProgressRecords(
        from oldEpisodeID: String,
        to newEpisodeID: String,
        canonicalFeedURL: String,
        modelContext: ModelContext
    ) throws {
        let targetOldID = oldEpisodeID
        let migratingRecords = try modelContext.fetch(
            FetchDescriptor<EpisodeProgressRecord>(
                predicate: #Predicate { record in
                    record.episodeID == targetOldID
                }
            )
        )
        guard !migratingRecords.isEmpty else {
            return
        }

        let targetNewID = newEpisodeID
        let existingRecords = try modelContext.fetch(
            FetchDescriptor<EpisodeProgressRecord>(
                predicate: #Predicate { record in
                    record.episodeID == targetNewID
                }
            )
        )
        for record in migratingRecords {
            record.episodeID = newEpisodeID
            record.podcastID = canonicalFeedURL
        }

        let group = migratingRecords + existingRecords
        if group.count > 1 {
            var mergeResult = SyncRepairResult()
            SyncDuplicateRepairer.mergeProgressGroup(
                group,
                key: .init(canonicalFeedURL: canonicalFeedURL, episodeID: newEpisodeID),
                modelContext: modelContext,
                result: &mergeResult
            )
        }
    }

    private static func migrateAdFreePassQueueItems(
        from oldEpisodeID: String,
        to newEpisodeID: String,
        canonicalFeedURL: String,
        modelContext: ModelContext
    ) throws {
        let targetOldID = oldEpisodeID
        let queueItems = try modelContext.fetch(
            FetchDescriptor<AdFreePassQueueItemRecord>(
                predicate: #Predicate { record in
                    record.episodeID == targetOldID
                }
            )
        )
        guard !queueItems.isEmpty else {
            return
        }

        // A successor already queued makes the old items redundant — one pass
        // per episode; re-keying would strand duplicate rows forever.
        let targetNewID = newEpisodeID
        let existingItems = try modelContext.fetch(
            FetchDescriptor<AdFreePassQueueItemRecord>(
                predicate: #Predicate { record in
                    record.episodeID == targetNewID
                }
            )
        )
        guard existingItems.isEmpty else {
            for item in queueItems {
                modelContext.delete(item)
            }
            return
        }

        for item in queueItems {
            item.episodeID = newEpisodeID
            item.podcastID = canonicalFeedURL
        }
    }
}
