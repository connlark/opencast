import Foundation
import SwiftData

/// Copies the playlists an earlier build kept in the device-local store into
/// the synced store, once per install.
///
/// Copies keep their logical keys and timestamps so a second device that
/// copies the same playlists converges through duplicate repair, and each
/// gets a fresh `dedupeUUID` because the legacy rows were never synced and
/// their UUIDs carry no cross-device meaning. Raw kind and origin strings
/// are copied as stored so a value this build does not know survives.
///
/// The completion flag lives in `UserDefaults` because Delete Data clears
/// every `LocalPreferenceRecord` but cannot reach the legacy rows, which
/// stay in the local store file; a flag kept there would copy them back.
/// Delete Data sets the flag itself after a successful wipe, so a copy that
/// had failed before the wipe is not retried either.
/// Tombstones are not read: a copy whose playlist was deleted elsewhere is
/// removed by the next repair pass.
enum PlaylistLocalStoreMigration {
    nonisolated static let completedDefaultsKey = "playlists.localStoreMigration.completed"

    /// Returns how many rows it inserted.
    @discardableResult
    static func apply(
        _ snapshot: LegacyLocalPlaylistSnapshot,
        modelContext: ModelContext,
        defaults: UserDefaults,
        save: (ModelContext) throws -> Void
    ) throws -> Int {
        guard !defaults.bool(forKey: completedDefaultsKey) else {
            return 0
        }

        var insertedCount = 0
        if !snapshot.isEmpty {
            // A failure leaves no half-copied rows pending in the shared
            // context, so the next launch retries from a clean store.
            do {
                insertedCount += try insertPlaylists(snapshot.playlists, modelContext: modelContext)
                insertedCount += try insertItems(snapshot.items, modelContext: modelContext)
                if insertedCount > 0 {
                    try save(modelContext)
                }
            } catch {
                modelContext.rollback()
                throw error
            }
        }
        defaults.set(true, forKey: completedDefaultsKey)
        return insertedCount
    }

    private static func insertPlaylists(
        _ playlists: [LegacyLocalPlaylistSnapshot.Playlist],
        modelContext: ModelContext
    ) throws -> Int {
        var knownPlaylistIDs = Set(
            try modelContext.fetch(FetchDescriptor<PlaylistRecord>()).map(\.playlistID)
        )
        var insertedCount = 0
        for playlist in playlists where !playlist.playlistID.isEmpty {
            guard knownPlaylistIDs.insert(playlist.playlistID).inserted else {
                continue
            }
            let record = PlaylistRecord(
                playlistID: playlist.playlistID,
                name: playlist.name,
                ruleJSON: playlist.ruleJSON,
                hidesPlayed: playlist.hidesPlayed,
                tintKey: playlist.tintKey,
                createdAt: playlist.createdAt,
                updatedAt: playlist.updatedAt
            )
            record.kindRawValue = playlist.kindRawValue
            record.originRawValue = playlist.originRawValue
            modelContext.insert(record)
            insertedCount += 1
        }
        return insertedCount
    }

    /// An item is copied even when its playlist is in neither the snapshot
    /// nor the store: the playlist row may still arrive from another device.
    private static func insertItems(
        _ items: [LegacyLocalPlaylistSnapshot.Item],
        modelContext: ModelContext
    ) throws -> Int {
        let existingItems = try modelContext.fetch(FetchDescriptor<PlaylistItemRecord>())
        var knownItemIDs = Set(existingItems.map(\.itemID))
        var knownPairs = Set(existingItems.map { PlaylistTombstoneIndex.ItemKey(playlistID: $0.playlistID, episodeID: $0.episodeID) })
        var insertedCount = 0
        for item in items {
            guard !item.itemID.isEmpty, !item.playlistID.isEmpty, !item.episodeID.isEmpty else {
                continue
            }
            let pair = PlaylistTombstoneIndex.ItemKey(playlistID: item.playlistID, episodeID: item.episodeID)
            guard !knownItemIDs.contains(item.itemID), !knownPairs.contains(pair) else {
                continue
            }
            knownItemIDs.insert(item.itemID)
            knownPairs.insert(pair)
            modelContext.insert(
                PlaylistItemRecord(
                    itemID: item.itemID,
                    playlistID: item.playlistID,
                    episodeID: item.episodeID,
                    podcastID: item.podcastID,
                    sortKey: item.sortKey,
                    addedAt: item.addedAt,
                    updatedAt: item.updatedAt,
                    episodeTitle: item.episodeTitle,
                    podcastTitle: item.podcastTitle,
                    artworkURL: item.artworkURL,
                    audioURL: item.audioURL,
                    duration: item.duration,
                    publishedAt: item.publishedAt
                )
            )
            insertedCount += 1
        }
        return insertedCount
    }
}
