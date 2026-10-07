import Foundation
import OpenCastCore
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Playlist tombstones and duplicate repair")
struct PlaylistSyncRepairTests {
    private static let feedURL = "https://example.com/playlist-repair.xml"
    private static let clearInstant = Date(timeIntervalSince1970: 1_700_000_000)
    private static let repairInstant = clearInstant.addingTimeInterval(1_000)
    private static let smallerIdentity = "aaaaaaaa-0000-0000-0000-000000000000"
    private static let middleIdentity = "bbbbbbbb-0000-0000-0000-000000000000"
    private static let largerIdentity = "cccccccc-0000-0000-0000-000000000000"

    private struct PlaylistRow: Equatable {
        var playlistID: String
        var name: String
        var kindRawValue: String
        var ruleJSON: String?
        var hidesPlayed: Bool
        var tintKey: String?
        var originRawValue: String
        var createdAt: Date
        var updatedAt: Date
        var dedupeUUID: String
    }

    private struct ItemRow: Equatable {
        var itemID: String
        var playlistID: String
        var episodeID: String
        var podcastID: String
        var sortKey: String
        var addedAt: Date
        var updatedAt: Date
        var episodeTitle: String
        var podcastTitle: String
        var artworkURL: String?
        var audioURL: String?
        var duration: TimeInterval?
        var publishedAt: Date?
        var dedupeUUID: String
    }

    @Test("A playlist tombstone deletes the playlist and all of its items, even ones added after it")
    func playlistTombstoneDeletesThePlaylistAndEveryItem() throws {
        let context = try makeContext()
        context.insert(PlaylistTombstoneRecord(playlistID: "gone", deletedAt: Self.clearInstant))
        context.insert(makePlaylist(playlistID: "gone", name: "Gone"))
        context.insert(makePlaylist(playlistID: "kept", name: "Kept"))
        context.insert(makeItem(playlistID: "gone", episodeID: "episode-1", addedAt: Self.clearInstant.addingTimeInterval(-100)))
        context.insert(makeItem(playlistID: "gone", episodeID: "episode-2", addedAt: Self.clearInstant.addingTimeInterval(100)))
        context.insert(makeItem(playlistID: "kept", episodeID: "episode-1", addedAt: Self.clearInstant.addingTimeInterval(-100)))
        try context.save()

        let result = try repair(context)

        #expect(try context.fetch(FetchDescriptor<PlaylistRecord>()).map(\.playlistID) == ["kept"])
        let items = try context.fetch(FetchDescriptor<PlaylistItemRecord>())
        #expect(items.map(\.playlistID) == ["kept"])
        #expect(items.map(\.episodeID) == ["episode-1"])
        #expect(result.tombstonedPlaylistRecordsDeleted == 1)
        #expect(result.tombstonedPlaylistItemRecordsDeleted == 2)
    }

    @Test("An item tombstone deletes memberships added at or before it and keeps later ones and other playlists")
    func itemTombstoneDeletesMembershipsAddedAtOrBeforeIt() throws {
        let context = try makeContext()
        for episodeID in ["episode-earlier", "episode-equal", "episode-later"] {
            context.insert(
                PlaylistTombstoneRecord(playlistID: "mix", episodeID: episodeID, deletedAt: Self.clearInstant)
            )
        }
        context.insert(makePlaylist(playlistID: "mix", name: "Mix"))
        context.insert(makePlaylist(playlistID: "other", name: "Other"))
        context.insert(
            makeItem(playlistID: "mix", episodeID: "episode-earlier", addedAt: Self.clearInstant.addingTimeInterval(-100))
        )
        context.insert(makeItem(playlistID: "mix", episodeID: "episode-equal", addedAt: Self.clearInstant))
        context.insert(
            makeItem(playlistID: "mix", episodeID: "episode-later", addedAt: Self.clearInstant.addingTimeInterval(100))
        )
        context.insert(
            makeItem(playlistID: "other", episodeID: "episode-earlier", addedAt: Self.clearInstant.addingTimeInterval(-100))
        )
        try context.save()

        let result = try repair(context)

        let pairs = try context.fetch(FetchDescriptor<PlaylistItemRecord>())
            .map { "\($0.playlistID)/\($0.episodeID)" }
            .sorted()
        #expect(pairs == ["mix/episode-later", "other/episode-earlier"])
        #expect(try context.fetch(FetchDescriptor<PlaylistRecord>()).count == 2)
        #expect(result.tombstonedPlaylistItemRecordsDeleted == 2)
        #expect(result.tombstonedPlaylistRecordsDeleted == 0)
    }

    @Test("A membership reordered after its removal is still deleted")
    func reorderedMembershipIsStillDeleted() throws {
        let context = try makeContext()
        context.insert(
            PlaylistTombstoneRecord(playlistID: "mix", episodeID: "episode-1", deletedAt: Self.clearInstant)
        )
        context.insert(makePlaylist(playlistID: "mix", name: "Mix"))
        context.insert(
            makeItem(
                playlistID: "mix",
                episodeID: "episode-1",
                sortKey: "q",
                addedAt: Self.clearInstant.addingTimeInterval(-100),
                updatedAt: Self.clearInstant.addingTimeInterval(100)
            )
        )
        try context.save()

        let result = try repair(context)

        #expect(try context.fetch(FetchDescriptor<PlaylistItemRecord>()).isEmpty)
        #expect(result.tombstonedPlaylistItemRecordsDeleted == 1)
    }

    @Test("Twin playlists keep the smallest identity, the newest content, and the earliest creation date")
    func twinPlaylistsConverge() throws {
        let context = try makeContext()
        for record in twinPlaylists() {
            context.insert(record)
        }
        try context.save()

        let result = try repair(context)

        let playlists = try context.fetch(FetchDescriptor<PlaylistRecord>())
        #expect(playlists.count == 1)
        let playlist = try #require(playlists.first)
        #expect(playlist.playlistID == "twin")
        #expect(playlist.dedupeUUID == Self.smallerIdentity)
        #expect(playlist.name == "Newest Name")
        #expect(playlist.kindRawValue == "smart")
        #expect(playlist.ruleJSON == "{\"version\":1}")
        #expect(playlist.hidesPlayed)
        #expect(playlist.tintKey == "teal")
        #expect(playlist.originRawValue == "ai")
        #expect(playlist.updatedAt == Self.clearInstant)
        #expect(playlist.createdAt == Self.clearInstant.addingTimeInterval(-900))
        #expect(result.duplicatePlaylistRecordsFound == 2)
        #expect(result.playlistGroupsMerged == 1)
        #expect(result.playlistRecordsDeleted == 2)
    }

    @Test("Twin items keep the newest added copy and its item ID, with the newest content")
    func twinItemsConverge() throws {
        let context = try makeContext()
        context.insert(makePlaylist(playlistID: "mix", name: "Mix"))
        for record in twinItems() {
            context.insert(record)
        }
        try context.save()

        let result = try repair(context)

        let items = try context.fetch(FetchDescriptor<PlaylistItemRecord>())
        #expect(items.count == 1)
        let item = try #require(items.first)
        #expect(item.dedupeUUID == Self.largerIdentity)
        #expect(item.itemID == "item-newest-added")
        #expect(item.playlistID == "mix")
        #expect(item.episodeID == "episode-1")
        #expect(item.podcastID == "https://example.com/newest.xml")
        #expect(item.sortKey == "q")
        #expect(item.updatedAt == Self.clearInstant)
        #expect(item.episodeTitle == "Newest Episode Title")
        #expect(item.podcastTitle == "Newest Show Title")
        #expect(item.artworkURL == "https://example.com/newest.jpg")
        #expect(item.audioURL == "https://example.com/newest.mp3")
        #expect(item.duration == 1_234)
        #expect(item.publishedAt == Self.clearInstant.addingTimeInterval(-5_000))
        #expect(item.addedAt == Self.clearInstant.addingTimeInterval(-50))
        #expect(result.duplicatePlaylistItemRecordsFound == 2)
        #expect(result.playlistItemGroupsMerged == 1)
        #expect(result.playlistItemRecordsDeleted == 2)
    }

    @Test("Twin item ties fall to the smallest identity, then the item ID, and a copy without identity is never kept")
    func keptItemTieBreaks() throws {
        let sameInstant = Self.clearInstant.addingTimeInterval(-10)
        let smallerIdentityLaterItemID = makeItem(
            playlistID: "mix", episodeID: "episode-1", itemID: "item-b", addedAt: sameInstant, dedupeUUID: Self.smallerIdentity
        )
        let smallerIdentityEarlierItemID = makeItem(
            playlistID: "mix", episodeID: "episode-1", itemID: "item-a", addedAt: sameInstant, dedupeUUID: Self.smallerIdentity
        )
        let largerIdentity = makeItem(
            playlistID: "mix", episodeID: "episode-1", itemID: "item-0", addedAt: sameInstant, dedupeUUID: Self.largerIdentity
        )
        let newestWithoutIdentity = makeItem(
            playlistID: "mix", episodeID: "episode-1", itemID: "item-!", addedAt: Self.clearInstant, dedupeUUID: ""
        )
        let group = [newestWithoutIdentity, largerIdentity, smallerIdentityLaterItemID, smallerIdentityEarlierItemID]

        #expect(PlaylistSyncRepairer.keptItem(in: group) === smallerIdentityEarlierItemID)
        #expect(PlaylistSyncRepairer.keptItem(in: group.reversed()) === smallerIdentityEarlierItemID)
        #expect(PlaylistSyncRepairer.keptItem(in: [newestWithoutIdentity]) == nil)
    }

    @Test("Twins inserted in the opposite order repair to the same rows")
    func insertionOrderDoesNotChangeTheOutcome() throws {
        let forward = try makeContext()
        let reversed = try makeContext()
        forward.insert(makePlaylist(playlistID: "mix", name: "Mix", dedupeUUID: Self.smallerIdentity))
        reversed.insert(makePlaylist(playlistID: "mix", name: "Mix", dedupeUUID: Self.smallerIdentity))
        for record in twinPlaylists() {
            forward.insert(record)
        }
        for record in twinItems() {
            forward.insert(record)
        }
        for record in twinPlaylists().reversed() {
            reversed.insert(record)
        }
        for record in twinItems().reversed() {
            reversed.insert(record)
        }
        try forward.save()
        try reversed.save()

        let forwardResult = try repair(forward)
        let reversedResult = try repair(reversed)

        #expect(try playlistRows(forward) == playlistRows(reversed))
        #expect(try itemRows(forward) == itemRows(reversed))
        #expect(try playlistRows(forward).map(\.playlistID) == ["mix", "twin"])
        #expect(try itemRows(forward).count == 1)
        #expect(forwardResult == reversedResult)
    }

    @Test("Items without a playlist row survive repair untouched")
    func parentlessItemsSurviveRepairUntouched() throws {
        let context = try makeContext()
        context.insert(makeItem(playlistID: "missing-parent", episodeID: "episode-1", itemID: "orphan-1"))
        context.insert(makeItem(playlistID: "missing-parent", episodeID: "episode-2", itemID: "orphan-2"))
        try context.save()
        let before = try itemRows(context)
        var saveCount = 0

        let result = try SyncDuplicateRepairer.repair(
            modelContext: context,
            now: Self.repairInstant,
            save: { modelContext in
                saveCount += 1
                try modelContext.save()
            }
        )

        #expect(before.count == 2)
        #expect(try itemRows(context) == before)
        #expect(!result.hasChanges)
        #expect(!result.playlistRowsChanged)
        #expect(saveCount == 0)
    }

    @Test("Rows with an empty playlist or episode key are neither grouped nor deleted")
    func rowsWithEmptyKeysAreLeftAlone() throws {
        let context = try makeContext()
        context.insert(makePlaylist(playlistID: "", name: "Keyless One", dedupeUUID: Self.smallerIdentity))
        context.insert(makePlaylist(playlistID: "", name: "Keyless Two", dedupeUUID: Self.middleIdentity))
        context.insert(makePlaylist(playlistID: "mix", name: "Mix"))
        context.insert(
            makeItem(playlistID: "mix", episodeID: "", itemID: "no-episode-1", dedupeUUID: Self.smallerIdentity)
        )
        context.insert(
            makeItem(playlistID: "mix", episodeID: "", itemID: "no-episode-2", dedupeUUID: Self.middleIdentity)
        )
        context.insert(
            makeItem(playlistID: "", episodeID: "episode-1", itemID: "no-playlist-1", dedupeUUID: Self.smallerIdentity)
        )
        context.insert(
            makeItem(playlistID: "", episodeID: "episode-1", itemID: "no-playlist-2", dedupeUUID: Self.middleIdentity)
        )
        try context.save()
        let playlistsBefore = try playlistRows(context)
        let itemsBefore = try itemRows(context)

        let result = try repair(context)

        #expect(playlistsBefore.count == 3)
        #expect(itemsBefore.count == 4)
        #expect(try playlistRows(context) == playlistsBefore)
        #expect(try itemRows(context) == itemsBefore)
        #expect(!result.playlistRowsChanged)
    }

    @Test("Superseded, covered, malformed and expired playlist tombstones are removed and a live one is kept")
    func playlistTombstoneHygiene() throws {
        let context = try makeContext()
        let now = Self.repairInstant
        // Live, and it covers the item tombstone below.
        context.insert(PlaylistTombstoneRecord(playlistID: "deleted", deletedAt: now.addingTimeInterval(-10)))
        context.insert(
            PlaylistTombstoneRecord(playlistID: "deleted", episodeID: "episode-1", deletedAt: now.addingTimeInterval(-20))
        )
        // The newer of the pair is the live one.
        context.insert(
            PlaylistTombstoneRecord(playlistID: "mix", episodeID: "episode-1", deletedAt: now.addingTimeInterval(-100))
        )
        context.insert(
            PlaylistTombstoneRecord(playlistID: "mix", episodeID: "episode-1", deletedAt: now.addingTimeInterval(-50))
        )
        context.insert(PlaylistTombstoneRecord(playlistID: "", deletedAt: now.addingTimeInterval(-10)))
        context.insert(PlaylistTombstoneRecord(playlistID: "mix", episodeID: "", deletedAt: now.addingTimeInterval(-10)))
        context.insert(
            PlaylistTombstoneRecord(
                playlistID: "expired",
                deletedAt: now.addingTimeInterval(-SyncDuplicateRepairer.tombstoneRetentionPeriod - 60)
            )
        )
        try context.save()

        let result = try repair(context, now: now)

        let remaining = try context.fetch(FetchDescriptor<PlaylistTombstoneRecord>())
            .map { "\($0.playlistID)/\($0.episodeID ?? "-")@\($0.deletedAt.timeIntervalSince(now))" }
            .sorted()
        #expect(remaining == ["deleted/-@-10.0", "mix/episode-1@-50.0"])
        #expect(result.expiredTombstonesDeleted == 5)
        #expect(result.hasChanges)
        #expect(!result.hasIssues)
        #expect(!result.playlistRowsChanged)
    }

    @Test("A playlist-only repair saves exactly once and a clean store does not save")
    func playlistRepairSavesOnceAndACleanStoreDoesNotSave() throws {
        let twinContext = try makeContext()
        for record in twinPlaylists() {
            twinContext.insert(record)
        }
        try twinContext.save()
        let cleanContext = try makeContext()
        cleanContext.insert(makePlaylist(playlistID: "clean", name: "Clean"))
        cleanContext.insert(makeItem(playlistID: "clean", episodeID: "episode-1"))
        try cleanContext.save()
        var twinSaveCount = 0
        var cleanSaveCount = 0

        let twinResult = try SyncDuplicateRepairer.repair(
            modelContext: twinContext,
            now: Self.repairInstant,
            save: { modelContext in
                twinSaveCount += 1
                try modelContext.save()
            }
        )
        let cleanResult = try SyncDuplicateRepairer.repair(
            modelContext: cleanContext,
            now: Self.repairInstant,
            save: { modelContext in
                cleanSaveCount += 1
                try modelContext.save()
            }
        )

        #expect(twinResult.hasChanges)
        #expect(twinSaveCount == 1)
        #expect(!twinContext.hasChanges)
        #expect(!cleanResult.hasChanges)
        #expect(cleanSaveCount == 0)
    }

    @Test("Playlist repair leaves shared tombstones alone and shared hygiene leaves playlist tombstones alone")
    func playlistAndSharedTombstonesStayApart() throws {
        let context = try makeContext()
        let now = Self.repairInstant
        context.insert(
            SyncTombstoneRecord(scope: .playlist, feedURL: "shared-key", deletedAt: now.addingTimeInterval(-10))
        )
        context.insert(
            SyncTombstoneRecord(
                scope: .playlistItem,
                feedURL: "shared-key",
                episodeID: "episode-1",
                deletedAt: now.addingTimeInterval(-10)
            )
        )
        context.insert(
            SyncTombstoneRecord(scope: .subscription, feedURL: Self.feedURL, deletedAt: now.addingTimeInterval(-10))
        )
        context.insert(PlaylistTombstoneRecord(playlistID: Self.feedURL, deletedAt: now.addingTimeInterval(-10)))
        context.insert(
            PlaylistTombstoneRecord(playlistID: "shared-key-other", episodeID: "episode-1", deletedAt: now.addingTimeInterval(-10))
        )
        context.insert(makePlaylist(playlistID: "shared-key", name: "Shared Key"))
        context.insert(makeItem(playlistID: "shared-key", episodeID: "episode-1", addedAt: now.addingTimeInterval(-100)))
        try context.save()

        let result = try repair(context, now: now)

        let sharedTombstones = try context.fetch(FetchDescriptor<SyncTombstoneRecord>())
            .map { "\($0.scope)/\($0.feedURL)/\($0.episodeID ?? "-")" }
            .sorted()
        #expect(
            sharedTombstones == [
                "\(SyncTombstoneScope.playlist.rawValue)/shared-key/-",
                "\(SyncTombstoneScope.playlistItem.rawValue)/shared-key/episode-1",
                "\(SyncTombstoneScope.subscription.rawValue)/\(Self.feedURL)/-"
            ].sorted()
        )
        let playlistTombstones = try context.fetch(FetchDescriptor<PlaylistTombstoneRecord>())
            .map { "\($0.playlistID)/\($0.episodeID ?? "-")" }
            .sorted()
        #expect(playlistTombstones == ["\(Self.feedURL)/-", "shared-key-other/episode-1"].sorted())
        #expect(try context.fetch(FetchDescriptor<PlaylistRecord>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<PlaylistItemRecord>()).count == 1)
        #expect(result.expiredTombstonesDeleted == 0)
        #expect(!result.hasChanges)
    }

    @Test("Twins without any dedupe identity merge into one row without crashing")
    func twinsWithoutIdentityMergeIntoOneRow() throws {
        let context = try makeContext()
        context.insert(
            makePlaylist(
                playlistID: "keyless",
                name: "Older Name",
                createdAt: Self.clearInstant.addingTimeInterval(-500),
                updatedAt: Self.clearInstant.addingTimeInterval(-100),
                dedupeUUID: ""
            )
        )
        context.insert(
            makePlaylist(
                playlistID: "keyless",
                name: "Newer Name",
                createdAt: Self.clearInstant.addingTimeInterval(-200),
                updatedAt: Self.clearInstant,
                dedupeUUID: ""
            )
        )
        context.insert(
            makeItem(
                playlistID: "keyless",
                episodeID: "episode-1",
                itemID: "older-item",
                addedAt: Self.clearInstant.addingTimeInterval(-100),
                updatedAt: Self.clearInstant.addingTimeInterval(-100),
                episodeTitle: "Older Title",
                dedupeUUID: ""
            )
        )
        context.insert(
            makeItem(
                playlistID: "keyless",
                episodeID: "episode-1",
                itemID: "newer-item",
                addedAt: Self.clearInstant.addingTimeInterval(-200),
                updatedAt: Self.clearInstant,
                episodeTitle: "Newer Title",
                dedupeUUID: ""
            )
        )
        try context.save()

        let result = try repair(context)

        let playlists = try context.fetch(FetchDescriptor<PlaylistRecord>())
        #expect(playlists.count == 1)
        let playlist = try #require(playlists.first)
        #expect(playlist.playlistID == "keyless")
        #expect(playlist.name == "Newer Name")
        #expect(playlist.createdAt == Self.clearInstant.addingTimeInterval(-500))
        #expect(playlist.updatedAt == Self.clearInstant)
        #expect(!playlist.dedupeUUID.isEmpty)
        let items = try context.fetch(FetchDescriptor<PlaylistItemRecord>())
        #expect(items.count == 1)
        let item = try #require(items.first)
        #expect(item.itemID == "newer-item")
        #expect(item.episodeTitle == "Newer Title")
        #expect(item.addedAt == Self.clearInstant.addingTimeInterval(-100))
        #expect(!item.dedupeUUID.isEmpty)
        #expect(result.playlistGroupsMerged == 1)
        #expect(result.playlistItemGroupsMerged == 1)
    }

    @Test("The result reports a playlist merge and a tombstone delete in its own counters and the aggregates")
    func resultReportsPlaylistMergeAndTombstoneDelete() throws {
        let context = try makeContext()
        context.insert(makePlaylist(playlistID: "twin", name: "Copy One", dedupeUUID: Self.smallerIdentity))
        context.insert(makePlaylist(playlistID: "twin", name: "Copy Two", dedupeUUID: Self.middleIdentity))
        context.insert(
            PlaylistTombstoneRecord(playlistID: "twin", episodeID: "episode-1", deletedAt: Self.clearInstant)
        )
        context.insert(
            makeItem(playlistID: "twin", episodeID: "episode-1", addedAt: Self.clearInstant.addingTimeInterval(-100))
        )
        try context.save()

        let result = try repair(context)

        #expect(result.duplicatePlaylistRecordsFound == 1)
        #expect(result.playlistGroupsMerged == 1)
        #expect(result.playlistRecordsDeleted == 1)
        #expect(result.duplicatePlaylistItemRecordsFound == 0)
        #expect(result.playlistItemGroupsMerged == 0)
        #expect(result.playlistItemRecordsDeleted == 0)
        #expect(result.tombstonedPlaylistRecordsDeleted == 0)
        #expect(result.tombstonedPlaylistItemRecordsDeleted == 1)
        #expect(result.duplicateRecordsFound == 1)
        #expect(result.groupsMerged == 1)
        #expect(result.recordsDeleted == 1)
        #expect(result.tombstonedRecordsDeleted == 1)
        #expect(result.playlistRowsChanged)
        #expect(result.hasIssues)
        #expect(result.hasChanges)
    }

    // MARK: - Fixtures

    private func makeContext() throws -> ModelContext {
        ModelContext(try OpenCastModelContainerFactory.make(inMemory: true))
    }

    private func repair(_ context: ModelContext, now: Date = Self.repairInstant) throws -> SyncRepairResult {
        try SyncDuplicateRepairer.repair(modelContext: context, now: now, save: { try $0.save() })
    }

    private func makePlaylist(
        playlistID: String,
        name: String,
        kindRawValue: String = "manual",
        ruleJSON: String? = nil,
        hidesPlayed: Bool = false,
        tintKey: String? = nil,
        originRawValue: String = "user",
        createdAt: Date = Self.clearInstant.addingTimeInterval(-1_000),
        updatedAt: Date = Self.clearInstant.addingTimeInterval(-1_000),
        dedupeUUID: String = UUID().uuidString
    ) -> PlaylistRecord {
        let record = PlaylistRecord(
            playlistID: playlistID,
            name: name,
            ruleJSON: ruleJSON,
            hidesPlayed: hidesPlayed,
            tintKey: tintKey,
            createdAt: createdAt,
            updatedAt: updatedAt,
            dedupeUUID: dedupeUUID
        )
        record.kindRawValue = kindRawValue
        record.originRawValue = originRawValue
        return record
    }

    private func makeItem(
        playlistID: String,
        episodeID: String,
        itemID: String = UUID().uuidString,
        podcastID: String = Self.feedURL,
        sortKey: String = "i",
        addedAt: Date = Self.clearInstant.addingTimeInterval(-1_000),
        updatedAt: Date? = nil,
        episodeTitle: String = "Fixture Episode",
        podcastTitle: String = "Fixture Show",
        artworkURL: String? = nil,
        audioURL: String? = nil,
        duration: TimeInterval? = nil,
        publishedAt: Date? = nil,
        dedupeUUID: String = UUID().uuidString
    ) -> PlaylistItemRecord {
        PlaylistItemRecord(
            itemID: itemID,
            playlistID: playlistID,
            episodeID: episodeID,
            podcastID: podcastID,
            sortKey: sortKey,
            addedAt: addedAt,
            updatedAt: updatedAt ?? addedAt,
            episodeTitle: episodeTitle,
            podcastTitle: podcastTitle,
            artworkURL: artworkURL,
            audioURL: audioURL,
            duration: duration,
            publishedAt: publishedAt,
            dedupeUUID: dedupeUUID
        )
    }

    /// Three copies of one playlist: the smallest identity holds the oldest
    /// content, the middle one the newest content, the largest the earliest
    /// creation date, so each merged field has a distinct source.
    private func twinPlaylists() -> [PlaylistRecord] {
        [
            makePlaylist(
                playlistID: "twin",
                name: "Oldest Name",
                createdAt: Self.clearInstant.addingTimeInterval(-500),
                updatedAt: Self.clearInstant.addingTimeInterval(-100),
                dedupeUUID: Self.smallerIdentity
            ),
            makePlaylist(
                playlistID: "twin",
                name: "Newest Name",
                kindRawValue: "smart",
                ruleJSON: "{\"version\":1}",
                hidesPlayed: true,
                tintKey: "teal",
                originRawValue: "ai",
                createdAt: Self.clearInstant.addingTimeInterval(-200),
                updatedAt: Self.clearInstant,
                dedupeUUID: Self.middleIdentity
            ),
            makePlaylist(
                playlistID: "twin",
                name: "Middle Name",
                createdAt: Self.clearInstant.addingTimeInterval(-900),
                updatedAt: Self.clearInstant.addingTimeInterval(-50),
                dedupeUUID: Self.largerIdentity
            )
        ]
    }

    /// Three copies of one membership: the smallest identity is the oldest,
    /// the middle one carries the newest content, the largest the newest
    /// added date (so the kept row is the one a smallest-identity pick would
    /// not have chosen).
    private func twinItems() -> [PlaylistItemRecord] {
        [
            makeItem(
                playlistID: "mix",
                episodeID: "episode-1",
                itemID: "item-smallest",
                sortKey: "i",
                addedAt: Self.clearInstant.addingTimeInterval(-300),
                episodeTitle: "Oldest Episode Title",
                podcastTitle: "Oldest Show Title",
                dedupeUUID: Self.smallerIdentity
            ),
            makeItem(
                playlistID: "mix",
                episodeID: "episode-1",
                itemID: "item-newest-content",
                podcastID: "https://example.com/newest.xml",
                sortKey: "q",
                addedAt: Self.clearInstant.addingTimeInterval(-100),
                updatedAt: Self.clearInstant,
                episodeTitle: "Newest Episode Title",
                podcastTitle: "Newest Show Title",
                artworkURL: "https://example.com/newest.jpg",
                audioURL: "https://example.com/newest.mp3",
                duration: 1_234,
                publishedAt: Self.clearInstant.addingTimeInterval(-5_000),
                dedupeUUID: Self.middleIdentity
            ),
            makeItem(
                playlistID: "mix",
                episodeID: "episode-1",
                itemID: "item-newest-added",
                sortKey: "m",
                addedAt: Self.clearInstant.addingTimeInterval(-50),
                updatedAt: Self.clearInstant.addingTimeInterval(-50),
                episodeTitle: "Latest Added Title",
                dedupeUUID: Self.largerIdentity
            )
        ]
    }

    private func playlistRows(_ context: ModelContext) throws -> [PlaylistRow] {
        try context.fetch(FetchDescriptor<PlaylistRecord>())
            .map { record in
                PlaylistRow(
                    playlistID: record.playlistID,
                    name: record.name,
                    kindRawValue: record.kindRawValue,
                    ruleJSON: record.ruleJSON,
                    hidesPlayed: record.hidesPlayed,
                    tintKey: record.tintKey,
                    originRawValue: record.originRawValue,
                    createdAt: record.createdAt,
                    updatedAt: record.updatedAt,
                    dedupeUUID: record.dedupeUUID
                )
            }
            .sorted { ($0.playlistID, $0.dedupeUUID) < ($1.playlistID, $1.dedupeUUID) }
    }

    private func itemRows(_ context: ModelContext) throws -> [ItemRow] {
        try context.fetch(FetchDescriptor<PlaylistItemRecord>())
            .map { record in
                ItemRow(
                    itemID: record.itemID,
                    playlistID: record.playlistID,
                    episodeID: record.episodeID,
                    podcastID: record.podcastID,
                    sortKey: record.sortKey,
                    addedAt: record.addedAt,
                    updatedAt: record.updatedAt,
                    episodeTitle: record.episodeTitle,
                    podcastTitle: record.podcastTitle,
                    artworkURL: record.artworkURL,
                    audioURL: record.audioURL,
                    duration: record.duration,
                    publishedAt: record.publishedAt,
                    dedupeUUID: record.dedupeUUID
                )
            }
            .sorted { ($0.playlistID, $0.episodeID, $0.itemID) < ($1.playlistID, $1.episodeID, $1.itemID) }
    }
}
