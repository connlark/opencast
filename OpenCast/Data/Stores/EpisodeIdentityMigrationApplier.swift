import Foundation
import OpenCastCore
import SwiftData

/// The per-match episode-identity migration body, shared by refresh
/// reconciliation and subscription migration: re-keys progress rows,
/// device-local sidecars, ad-free-pass queue items, and playlist items onto
/// the successor episode ID and tombstones the departed ID. Inserts into the passed
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
            try migrateNotes(
                from: match.departedEpisodeID,
                to: match.successorEpisodeID,
                modelContext: modelContext
            )
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
            try migratePlaylistItems(
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

    private static func migrateNotes(
        from oldEpisodeID: String,
        to newEpisodeID: String,
        modelContext: ModelContext
    ) throws {
        guard oldEpisodeID != newEpisodeID else { return }
        let notes = try modelContext.fetch(FetchDescriptor<EpisodeNoteRecord>(
            predicate: #Predicate { $0.episodeID == oldEpisodeID || $0.episodeID == newEpisodeID }
        ))
        guard notes.contains(where: { $0.episodeID == oldEpisodeID }) else { return }
        for note in notes { note.episodeID = newEpisodeID }
        let wholeEpisode = notes.filter(\.isEpisodeWide).sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.noteID < $1.noteID
        }
        // Identity collisions must preserve both texts while keeping one episode note.
        if let kept = wholeEpisode.first, wholeEpisode.count > 1 {
            kept.text = wholeEpisode.map(\.text).joined(separator: "\n\n")
            for note in wholeEpisode.dropFirst() { modelContext.delete(note) }
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

    /// Unlike the ad-free queue, a playlist may hold an episode once per
    /// playlist, so the collision rule is scoped to each playlist: a live
    /// successor already in that playlist makes the departed rows redundant
    /// there only (a successor an item tombstone shadows does not count).
    /// Otherwise one departed row per playlist is re-keyed and its twins are
    /// deleted. `itemID` and `sortKey` stay put so the item keeps its identity
    /// and position; `addedAt` and `updatedAt` are untouched because a re-key
    /// is not an edit.
    ///
    /// No item tombstone is written for the departed pair. The re-keyed row
    /// keeps its `addedAt`, so such a tombstone would shadow the user's own
    /// membership whenever the row comes back to that pair: a feed that moves
    /// back to its earlier URL, a reverted GUID change, or another device's
    /// stale copy of the same record winning the conflict. Without it, each of
    /// those heals on the next re-key. A departed row that an existing
    /// tombstone already shadows is a removal repair has not applied yet, so
    /// it is deleted rather than carried out from under that tombstone.
    private static func migratePlaylistItems(
        from oldEpisodeID: String,
        to newEpisodeID: String,
        canonicalFeedURL: String,
        modelContext: ModelContext
    ) throws {
        let targetOldID = oldEpisodeID
        let departedItems = try modelContext.fetch(
            FetchDescriptor<PlaylistItemRecord>(
                predicate: #Predicate { record in
                    record.episodeID == targetOldID
                }
            )
        )
        guard !departedItems.isEmpty else {
            return
        }

        let tombstoneIndex = PlaylistTombstoneIndex(
            try modelContext.fetch(FetchDescriptor<PlaylistTombstoneRecord>())
        )
        var departedItemsByPlaylist: [String: [PlaylistItemRecord]] = [:]
        for item in departedItems {
            if tombstoneIndex.shadowsItem(
                playlistID: item.playlistID,
                episodeID: item.episodeID,
                addedAt: item.addedAt
            ) {
                modelContext.delete(item)
            } else {
                departedItemsByPlaylist[item.playlistID, default: []].append(item)
            }
        }

        let targetNewID = newEpisodeID
        let successorItems = try modelContext.fetch(
            FetchDescriptor<PlaylistItemRecord>(
                predicate: #Predicate { record in
                    record.episodeID == targetNewID
                }
            )
        )
        // A successor an item tombstone already shadows is one the next
        // repair deletes, so it covers nothing: deleting the departed row
        // on its account would drop a membership the user added after
        // that removal.
        let coveredPlaylistIDs = Set(
            successorItems
                .filter { item in
                    !tombstoneIndex.shadowsItem(
                        playlistID: item.playlistID,
                        episodeID: item.episodeID,
                        addedAt: item.addedAt
                    )
                }
                .map(\.playlistID)
        )
        for (playlistID, items) in departedItemsByPlaylist {
            // The kept twin is the one the store's listing and duplicate
            // repair keep, so memory and every device agree on the row,
            // whatever order the store returned them in.
            let keep = coveredPlaylistIDs.contains(playlistID)
                ? nil
                : PlaylistSyncRepairer.keptItem(in: items) ?? items.min(by: PlaylistSyncRepairer.isFresherItem)
            for item in items where item !== keep {
                modelContext.delete(item)
            }
            if let keep {
                keep.episodeID = newEpisodeID
                keep.podcastID = canonicalFeedURL
            }
        }
    }
}
