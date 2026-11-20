import Foundation
import SwiftData

/// Never saves; the caller saves the whole pass once. Twin picks depend only on write-once
/// fields, so every device converges without cross-deleting. A missing playlist row never
/// deletes its items: it may not have synced yet, and only a tombstone proves a delete.
enum PlaylistSyncRepairer {
    static func repair(modelContext: ModelContext, now: Date, result: inout SyncRepairResult) throws {
        let tombstones = try modelContext.fetch(FetchDescriptor<PlaylistTombstoneRecord>())
        let index = PlaylistTombstoneIndex(tombstones)

        let playlists = try modelContext.fetch(FetchDescriptor<PlaylistRecord>())
        var survivingPlaylists: [PlaylistRecord] = []
        survivingPlaylists.reserveCapacity(playlists.count)
        for playlist in playlists {
            if index.shadowsPlaylist(playlist.playlistID) {
                modelContext.delete(playlist)
                result.tombstonedPlaylistRecordsDeleted += 1
            } else {
                survivingPlaylists.append(playlist)
            }
        }

        let items = try modelContext.fetch(FetchDescriptor<PlaylistItemRecord>())
        var survivingItems: [PlaylistItemRecord] = []
        survivingItems.reserveCapacity(items.count)
        for item in items {
            if index.shadowsItem(playlistID: item.playlistID, episodeID: item.episodeID, addedAt: item.addedAt) {
                modelContext.delete(item)
                result.tombstonedPlaylistItemRecordsDeleted += 1
            } else {
                survivingItems.append(item)
            }
        }

        let playlistGroups = Dictionary(grouping: survivingPlaylists.filter { !$0.playlistID.isEmpty }, by: \.playlistID)
        for (playlistID, group) in playlistGroups where group.count > 1 {
            mergePlaylistGroup(group, playlistID: playlistID, modelContext: modelContext, result: &result)
        }

        let itemGroups = Dictionary(
            grouping: survivingItems.filter { !$0.playlistID.isEmpty && !$0.episodeID.isEmpty }
        ) { item in
            PlaylistTombstoneIndex.ItemKey(playlistID: item.playlistID, episodeID: item.episodeID)
        }
        for (key, group) in itemGroups where group.count > 1 {
            mergeItemGroup(group, key: key, modelContext: modelContext, result: &result)
        }

        collectSpentTombstones(tombstones, index: index, now: now, modelContext: modelContext, result: &result)
    }

    // MARK: - Kept rows

    /// nil when no copy carries an identity; the merge then replaces the group with a fresh row.
    static func keptPlaylist(in group: [PlaylistRecord]) -> PlaylistRecord? {
        SyncDuplicateRepairer.deterministicWinner(in: group)
    }

    /// The newest `addedAt` wins: it is write-once and gates item tombstones, so an add made after
    /// a removal on another offline device must not fold into the older row that device deletes.
    static func keptItem(in group: [PlaylistItemRecord]) -> PlaylistItemRecord? {
        group
            .filter { !$0.dedupeUUID.isEmpty }
            .min { lhs, rhs in
                if lhs.addedAt != rhs.addedAt {
                    return lhs.addedAt > rhs.addedAt
                }
                if lhs.dedupeUUID != rhs.dedupeUUID {
                    return lhs.dedupeUUID < rhs.dedupeUUID
                }
                return lhs.itemID < rhs.itemID
            }
    }

    // MARK: - Playlists

    private static func mergePlaylistGroup(
        _ group: [PlaylistRecord],
        playlistID: String,
        modelContext: ModelContext,
        result: inout SyncRepairResult
    ) {
        guard let source = group.min(by: isFresherPlaylist) else {
            return
        }
        // Earliest, not the source's: a twin is the same playlist created on
        // another device, and its creation is the first copy's.
        let createdAt = group.map(\.createdAt).min() ?? source.createdAt

        if let keep = keptPlaylist(in: group) {
            SyncDuplicateRepairer.setIfChanged(keep, \.name, source.name)
            SyncDuplicateRepairer.setIfChanged(keep, \.kindRawValue, source.kindRawValue)
            SyncDuplicateRepairer.setIfChanged(keep, \.ruleJSON, source.ruleJSON)
            SyncDuplicateRepairer.setIfChanged(keep, \.hidesPlayed, source.hidesPlayed)
            SyncDuplicateRepairer.setIfChanged(keep, \.tintKey, source.tintKey)
            SyncDuplicateRepairer.setIfChanged(keep, \.originRawValue, source.originRawValue)
            SyncDuplicateRepairer.setIfChanged(keep, \.updatedAt, source.updatedAt)
            SyncDuplicateRepairer.setIfChanged(keep, \.createdAt, createdAt)

            for playlist in group where playlist !== keep {
                modelContext.delete(playlist)
            }
        } else {
            // No copy carries an identity, so peers could keep opposite copies and cross-delete
            // both. One freshly identified row replaces the group; competing replacements
            // converge on the smaller UUID in a later pass.
            let merged = PlaylistRecord(
                playlistID: playlistID,
                name: source.name,
                ruleJSON: source.ruleJSON,
                hidesPlayed: source.hidesPlayed,
                tintKey: source.tintKey,
                createdAt: createdAt,
                updatedAt: source.updatedAt
            )
            // Raw strings, not the enums: a kind or origin this build does not
            // know must survive the merge.
            merged.kindRawValue = source.kindRawValue
            merged.originRawValue = source.originRawValue
            modelContext.insert(merged)
            for playlist in group {
                modelContext.delete(playlist)
            }
        }

        result.duplicatePlaylistRecordsFound += group.count - 1
        result.playlistGroupsMerged += 1
        result.playlistRecordsDeleted += group.count - 1
    }

    /// Ties fall back to the content itself, so the pick never depends on fetch order.
    static func isFresherPlaylist(_ candidate: PlaylistRecord, than current: PlaylistRecord) -> Bool {
        if candidate.updatedAt != current.updatedAt {
            return candidate.updatedAt > current.updatedAt
        }
        if candidate.dedupeUUID != current.dedupeUUID {
            return candidate.dedupeUUID < current.dedupeUUID
        }
        return contentFingerprint(of: candidate).lexicographicallyPrecedes(contentFingerprint(of: current))
    }

    private static func contentFingerprint(of playlist: PlaylistRecord) -> [String] {
        [
            playlist.name,
            playlist.kindRawValue,
            fingerprint(playlist.ruleJSON),
            playlist.hidesPlayed ? "1" : "0",
            fingerprint(playlist.tintKey),
            playlist.originRawValue
        ]
    }

    // MARK: - Items

    private static func mergeItemGroup(
        _ group: [PlaylistItemRecord],
        key: PlaylistTombstoneIndex.ItemKey,
        modelContext: ModelContext,
        result: inout SyncRepairResult
    ) {
        guard let source = group.min(by: isFresherItem) else {
            return
        }

        if let keep = keptItem(in: group) {
            // `addedAt` stays the kept row's own: it gates item tombstones, and an older twin's
            // date must not drag a legitimate re-add behind an in-flight removal.
            SyncDuplicateRepairer.setIfChanged(keep, \.podcastID, source.podcastID)
            SyncDuplicateRepairer.setIfChanged(keep, \.sortKey, source.sortKey)
            SyncDuplicateRepairer.setIfChanged(keep, \.updatedAt, source.updatedAt)
            SyncDuplicateRepairer.setIfChanged(keep, \.episodeTitle, source.episodeTitle)
            SyncDuplicateRepairer.setIfChanged(keep, \.podcastTitle, source.podcastTitle)
            SyncDuplicateRepairer.setIfChanged(keep, \.artworkURL, source.artworkURL)
            SyncDuplicateRepairer.setIfChanged(keep, \.audioURL, source.audioURL)
            SyncDuplicateRepairer.setIfChanged(keep, \.duration, source.duration)
            SyncDuplicateRepairer.setIfChanged(keep, \.publishedAt, source.publishedAt)

            for item in group where item !== keep {
                modelContext.delete(item)
            }
        } else {
            // The newest `addedAt`, so a re-add stays ahead of an in-flight removal.
            let addedAt = group.map(\.addedAt).max() ?? source.addedAt
            modelContext.insert(
                PlaylistItemRecord(
                    itemID: source.itemID,
                    playlistID: key.playlistID,
                    episodeID: key.episodeID,
                    podcastID: source.podcastID,
                    sortKey: source.sortKey,
                    addedAt: addedAt,
                    updatedAt: source.updatedAt,
                    episodeTitle: source.episodeTitle,
                    podcastTitle: source.podcastTitle,
                    artworkURL: source.artworkURL,
                    audioURL: source.audioURL,
                    duration: source.duration,
                    publishedAt: source.publishedAt
                )
            )
            for item in group {
                modelContext.delete(item)
            }
        }

        result.duplicatePlaylistItemRecordsFound += group.count - 1
        result.playlistItemGroupsMerged += 1
        result.playlistItemRecordsDeleted += group.count - 1
    }

    /// `itemID` leads the content because the identity-less merge carries the source's `itemID`.
    static func isFresherItem(_ candidate: PlaylistItemRecord, than current: PlaylistItemRecord) -> Bool {
        if candidate.updatedAt != current.updatedAt {
            return candidate.updatedAt > current.updatedAt
        }
        if candidate.dedupeUUID != current.dedupeUUID {
            return candidate.dedupeUUID < current.dedupeUUID
        }
        return contentFingerprint(of: candidate).lexicographicallyPrecedes(contentFingerprint(of: current))
    }

    private static func contentFingerprint(of item: PlaylistItemRecord) -> [String] {
        [
            item.itemID,
            item.podcastID,
            item.sortKey,
            item.episodeTitle,
            item.podcastTitle,
            fingerprint(item.artworkURL),
            fingerprint(item.audioURL),
            fingerprint(item.duration.map { String($0) }),
            fingerprint(item.publishedAt.map { String($0.timeIntervalSinceReferenceDate) })
        ]
    }

    /// Keeps nil and the empty string apart in the content order.
    private static func fingerprint(_ value: String?) -> String {
        value.map { "1" + $0 } ?? "0"
    }

    // MARK: - Tombstones

    private static func collectSpentTombstones(
        _ tombstones: [PlaylistTombstoneRecord],
        index: PlaylistTombstoneIndex,
        now: Date,
        modelContext: ModelContext,
        result: inout SyncRepairResult
    ) {
        var newestPlaylistClears: [String: Date] = [:]
        for tombstone in tombstones where tombstone.episodeID == nil {
            newestPlaylistClears[tombstone.playlistID] = max(
                newestPlaylistClears[tombstone.playlistID] ?? tombstone.deletedAt,
                tombstone.deletedAt
            )
        }

        for tombstone in tombstones {
            if isSpent(tombstone, index: index, newestPlaylistClears: newestPlaylistClears, now: now) {
                modelContext.delete(tombstone)
                result.expiredTombstonesDeleted += 1
            }
        }
    }

    private static func isSpent(
        _ tombstone: PlaylistTombstoneRecord,
        index: PlaylistTombstoneIndex,
        newestPlaylistClears: [String: Date],
        now: Date
    ) -> Bool {
        if tombstone.playlistID.isEmpty || tombstone.episodeID?.isEmpty == true {
            return true
        }
        if now.timeIntervalSince(tombstone.deletedAt) > SyncDuplicateRepairer.tombstoneRetentionPeriod {
            return true
        }
        guard let episodeID = tombstone.episodeID else {
            return (newestPlaylistClears[tombstone.playlistID] ?? tombstone.deletedAt) > tombstone.deletedAt
        }
        if index.shadowsPlaylist(tombstone.playlistID) {
            return true
        }
        let key = PlaylistTombstoneIndex.ItemKey(playlistID: tombstone.playlistID, episodeID: episodeID)
        return (index.latestItemClears[key] ?? tombstone.deletedAt) > tombstone.deletedAt
    }
}
