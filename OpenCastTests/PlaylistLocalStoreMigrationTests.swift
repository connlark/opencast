import Foundation
import OpenCastCore
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Copying locally stored playlists into the synced store")
struct PlaylistLocalStoreMigrationTests {
    private static let feedURL = "https://example.com/local-copy.xml"
    private static let createdAt = Date(timeIntervalSinceReferenceDate: 813_011_142.85376)
    private static let updatedAt = Date(timeIntervalSinceReferenceDate: 813_011_160.50152099)
    private static let addedAt = Date(timeIntervalSinceReferenceDate: 813_010_958.27637696)
    private static let publishedAt = Date(timeIntervalSinceReferenceDate: 812_851_200)

    private struct SaveFailure: Error {}

    @Test("Copies keep their keys, timestamps and fields and get a fresh dedupe identity")
    func copiesKeepKeysAndFieldsWithFreshIdentity() throws {
        let context = try makeContext()
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var saveCount = 0
        let snapshot = LegacyLocalPlaylistSnapshot(
            playlists: [
                makePlaylist(
                    playlistID: "copied",
                    name: "Copied Smart",
                    kindRawValue: "smart",
                    ruleJSON: "{\"version\":1}",
                    hidesPlayed: true,
                    tintKey: "red"
                )
            ],
            items: [
                makeItem(
                    itemID: "copied-item",
                    playlistID: "copied",
                    episodeID: "copied-episode",
                    artworkURL: "https://example.com/copied.jpg",
                    audioURL: "https://example.com/copied.mp3",
                    duration: 3_725,
                    publishedAt: Self.publishedAt
                )
            ]
        )

        let inserted = try PlaylistLocalStoreMigration.apply(
            snapshot,
            modelContext: context,
            defaults: defaults,
            save: { modelContext in
                saveCount += 1
                try modelContext.save()
            }
        )

        #expect(inserted == 2)
        #expect(saveCount == 1)
        let playlist = try #require(try context.fetch(FetchDescriptor<PlaylistRecord>()).first)
        #expect(playlist.playlistID == "copied")
        #expect(playlist.name == "Copied Smart")
        #expect(playlist.kindRawValue == "smart")
        #expect(playlist.ruleJSON == "{\"version\":1}")
        #expect(playlist.hidesPlayed)
        #expect(playlist.tintKey == "red")
        #expect(playlist.originRawValue == "user")
        #expect(playlist.createdAt == Self.createdAt)
        #expect(playlist.updatedAt == Self.updatedAt)
        #expect(!playlist.dedupeUUID.isEmpty)
        let item = try #require(try context.fetch(FetchDescriptor<PlaylistItemRecord>()).first)
        #expect(item.itemID == "copied-item")
        #expect(item.playlistID == "copied")
        #expect(item.episodeID == "copied-episode")
        #expect(item.podcastID == Self.feedURL)
        #expect(item.sortKey == "i")
        #expect(item.addedAt == Self.addedAt)
        #expect(item.updatedAt == Self.addedAt)
        #expect(item.episodeTitle == "Copied Episode")
        #expect(item.podcastTitle == "Copied Show")
        #expect(item.artworkURL == "https://example.com/copied.jpg")
        #expect(item.audioURL == "https://example.com/copied.mp3")
        #expect(item.duration == 3_725)
        #expect(item.publishedAt == Self.publishedAt)
        #expect(!item.dedupeUUID.isEmpty)
        #expect(item.dedupeUUID != playlist.dedupeUUID)
        #expect(defaults.bool(forKey: PlaylistLocalStoreMigration.completedDefaultsKey))
    }

    @Test("Kind and origin strings this build does not know are copied as stored")
    func unknownKindAndOriginStringsArePreserved() throws {
        let context = try makeContext()
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let snapshot = LegacyLocalPlaylistSnapshot(
            playlists: [
                makePlaylist(
                    playlistID: "future",
                    name: "Future",
                    kindRawValue: "future-kind",
                    originRawValue: "future-origin"
                )
            ]
        )

        try PlaylistLocalStoreMigration.apply(snapshot, modelContext: context, defaults: defaults, save: { try $0.save() })

        let playlist = try #require(try context.fetch(FetchDescriptor<PlaylistRecord>()).first)
        #expect(playlist.kindRawValue == "future-kind")
        #expect(playlist.originRawValue == "future-origin")
    }

    @Test("Rows already in the store by playlist ID, item ID or membership are skipped")
    func rowsAlreadyPresentAreSkipped() throws {
        let context = try makeContext()
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        context.insert(PlaylistRecord(playlistID: "present", name: "Synced Name"))
        context.insert(
            PlaylistItemRecord(
                itemID: "present-item",
                playlistID: "present",
                episodeID: "episode-1",
                podcastID: Self.feedURL,
                sortKey: "i",
                episodeTitle: "Synced Episode",
                podcastTitle: "Synced Show"
            )
        )
        context.insert(
            PlaylistItemRecord(
                itemID: "present-pair",
                playlistID: "present",
                episodeID: "episode-2",
                podcastID: Self.feedURL,
                sortKey: "q",
                episodeTitle: "Synced Episode Two",
                podcastTitle: "Synced Show"
            )
        )
        try context.save()
        let snapshot = LegacyLocalPlaylistSnapshot(
            playlists: [
                makePlaylist(playlistID: "present", name: "Local Name"),
                makePlaylist(playlistID: "new", name: "New")
            ],
            items: [
                makeItem(itemID: "present-item", playlistID: "new", episodeID: "episode-9"),
                makeItem(itemID: "local-pair", playlistID: "present", episodeID: "episode-2"),
                makeItem(itemID: "new-item", playlistID: "new", episodeID: "episode-1")
            ]
        )

        let inserted = try PlaylistLocalStoreMigration.apply(
            snapshot,
            modelContext: context,
            defaults: defaults,
            save: { try $0.save() }
        )

        #expect(inserted == 2)
        let playlists = try context.fetch(FetchDescriptor<PlaylistRecord>())
        #expect(playlists.map(\.playlistID).sorted() == ["new", "present"])
        #expect(playlists.first { $0.playlistID == "present" }?.name == "Synced Name")
        let items = try context.fetch(FetchDescriptor<PlaylistItemRecord>())
        #expect(items.map(\.itemID).sorted() == ["new-item", "present-item", "present-pair"])
        #expect(items.first { $0.itemID == "present-item" }?.playlistID == "present")
        #expect(items.first { $0.itemID == "present-pair" }?.episodeTitle == "Synced Episode Two")
    }

    @Test("Running twice without the flag copies the rows once")
    func twoPassesWithoutTheFlagInsertOnce() throws {
        let context = try makeContext()
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var saveCount = 0
        let snapshot = LegacyLocalPlaylistSnapshot(
            playlists: [makePlaylist(playlistID: "once", name: "Once")],
            items: [makeItem(itemID: "once-item", playlistID: "once", episodeID: "episode-1")]
        )
        let save: (ModelContext) throws -> Void = { modelContext in
            saveCount += 1
            try modelContext.save()
        }

        let firstInserted = try PlaylistLocalStoreMigration.apply(
            snapshot,
            modelContext: context,
            defaults: defaults,
            save: save
        )
        defaults.removeObject(forKey: PlaylistLocalStoreMigration.completedDefaultsKey)
        let secondInserted = try PlaylistLocalStoreMigration.apply(
            snapshot,
            modelContext: context,
            defaults: defaults,
            save: save
        )

        #expect(firstInserted == 2)
        #expect(secondInserted == 0)
        #expect(saveCount == 1)
        #expect(try context.fetch(FetchDescriptor<PlaylistRecord>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<PlaylistItemRecord>()).count == 1)
        #expect(defaults.bool(forKey: PlaylistLocalStoreMigration.completedDefaultsKey))
    }

    @Test("With the flag set nothing is copied and nothing is saved")
    func flagSetInsertsNothing() throws {
        let context = try makeContext()
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: PlaylistLocalStoreMigration.completedDefaultsKey)
        var saveCount = 0
        let snapshot = LegacyLocalPlaylistSnapshot(
            playlists: [makePlaylist(playlistID: "skipped", name: "Skipped")],
            items: [makeItem(itemID: "skipped-item", playlistID: "skipped", episodeID: "episode-1")]
        )

        let inserted = try PlaylistLocalStoreMigration.apply(
            snapshot,
            modelContext: context,
            defaults: defaults,
            save: { modelContext in
                saveCount += 1
                try modelContext.save()
            }
        )

        #expect(inserted == 0)
        #expect(saveCount == 0)
        #expect(!context.hasChanges)
        #expect(try context.fetch(FetchDescriptor<PlaylistRecord>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<PlaylistItemRecord>()).isEmpty)
    }

    @Test("An empty snapshot sets the flag and saves nothing")
    func emptySnapshotSetsTheFlagAndSavesNothing() throws {
        let context = try makeContext()
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var saveCount = 0

        let inserted = try PlaylistLocalStoreMigration.apply(
            LegacyLocalPlaylistSnapshot(),
            modelContext: context,
            defaults: defaults,
            save: { modelContext in
                saveCount += 1
                try modelContext.save()
            }
        )

        #expect(inserted == 0)
        #expect(saveCount == 0)
        #expect(defaults.bool(forKey: PlaylistLocalStoreMigration.completedDefaultsKey))
    }

    @Test("A failed save leaves the flag unset and no copies pending in the context")
    func failedSaveLeavesTheFlagUnsetAndNothingPending() throws {
        let context = try makeContext()
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let snapshot = LegacyLocalPlaylistSnapshot(
            playlists: [makePlaylist(playlistID: "unsaved", name: "Unsaved")],
            items: [makeItem(itemID: "unsaved-item", playlistID: "unsaved", episodeID: "episode-1")]
        )

        #expect(throws: SaveFailure.self) {
            try PlaylistLocalStoreMigration.apply(
                snapshot,
                modelContext: context,
                defaults: defaults,
                save: { _ in throw SaveFailure() }
            )
        }

        #expect(!defaults.bool(forKey: PlaylistLocalStoreMigration.completedDefaultsKey))
        #expect(!context.hasChanges)
        #expect(try context.fetch(FetchDescriptor<PlaylistRecord>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<PlaylistItemRecord>()).isEmpty)
    }

    @Test("An item whose playlist is in neither the snapshot nor the store is still copied")
    func itemWithAbsentPlaylistIsStillCopied() throws {
        let context = try makeContext()
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let snapshot = LegacyLocalPlaylistSnapshot(
            items: [makeItem(itemID: "stray-item", playlistID: "elsewhere", episodeID: "episode-1")]
        )

        let inserted = try PlaylistLocalStoreMigration.apply(
            snapshot,
            modelContext: context,
            defaults: defaults,
            save: { try $0.save() }
        )

        #expect(inserted == 1)
        #expect(try context.fetch(FetchDescriptor<PlaylistRecord>()).isEmpty)
        let items = try context.fetch(FetchDescriptor<PlaylistItemRecord>())
        #expect(items.map(\.itemID) == ["stray-item"])
        #expect(items.map(\.playlistID) == ["elsewhere"])
    }

    @Test("A copy of a playlist deleted on another device is removed by the next repair")
    func tombstonedCopyIsRemovedByTheNextRepair() throws {
        let context = try makeContext()
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = Date.now
        context.insert(PlaylistTombstoneRecord(playlistID: "deleted-elsewhere", deletedAt: now.addingTimeInterval(-60)))
        context.insert(PlaylistRecord(playlistID: "kept", name: "Kept"))
        try context.save()
        let snapshot = LegacyLocalPlaylistSnapshot(
            playlists: [makePlaylist(playlistID: "deleted-elsewhere", name: "Deleted Elsewhere")],
            items: [makeItem(itemID: "deleted-item", playlistID: "deleted-elsewhere", episodeID: "episode-1")]
        )

        let inserted = try PlaylistLocalStoreMigration.apply(
            snapshot,
            modelContext: context,
            defaults: defaults,
            save: { try $0.save() }
        )
        #expect(inserted == 2)

        let result = try SyncDuplicateRepairer.repair(modelContext: context, now: now, save: { try $0.save() })

        #expect(try context.fetch(FetchDescriptor<PlaylistRecord>()).map(\.playlistID) == ["kept"])
        #expect(try context.fetch(FetchDescriptor<PlaylistItemRecord>()).isEmpty)
        #expect(result.tombstonedPlaylistRecordsDeleted == 1)
        #expect(result.tombstonedPlaylistItemRecordsDeleted == 1)
    }

    // MARK: - Fixtures

    private func makeContext() throws -> ModelContext {
        ModelContext(try OpenCastModelContainerFactory.make(inMemory: true))
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "playlist-local-copy-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    private func makePlaylist(
        playlistID: String,
        name: String,
        kindRawValue: String = "manual",
        ruleJSON: String? = nil,
        hidesPlayed: Bool = false,
        tintKey: String? = nil,
        originRawValue: String = "user"
    ) -> LegacyLocalPlaylistSnapshot.Playlist {
        LegacyLocalPlaylistSnapshot.Playlist(
            playlistID: playlistID,
            name: name,
            kindRawValue: kindRawValue,
            ruleJSON: ruleJSON,
            hidesPlayed: hidesPlayed,
            tintKey: tintKey,
            originRawValue: originRawValue,
            createdAt: Self.createdAt,
            updatedAt: Self.updatedAt
        )
    }

    private func makeItem(
        itemID: String,
        playlistID: String,
        episodeID: String,
        artworkURL: String? = nil,
        audioURL: String? = nil,
        duration: TimeInterval? = nil,
        publishedAt: Date? = nil
    ) -> LegacyLocalPlaylistSnapshot.Item {
        LegacyLocalPlaylistSnapshot.Item(
            itemID: itemID,
            playlistID: playlistID,
            episodeID: episodeID,
            podcastID: Self.feedURL,
            sortKey: "i",
            addedAt: Self.addedAt,
            updatedAt: Self.addedAt,
            episodeTitle: "Copied Episode",
            podcastTitle: "Copied Show",
            artworkURL: artworkURL,
            audioURL: audioURL,
            duration: duration,
            publishedAt: publishedAt
        )
    }
}
