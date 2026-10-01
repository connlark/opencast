import Foundation
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Playlist store")
struct PlaylistStoreTests {
    @Test("Create, rename and delete persist, and delete removes the playlist's items")
    func createRenameDelete() throws {
        let fixture = try makeFixture()
        let commute = try #require(
            fixture.store.create(name: "  Commute  ", kind: .manual, modelContext: fixture.context)
        )
        let other = try #require(
            fixture.store.create(name: "Other", kind: .manual, modelContext: fixture.context)
        )
        #expect(commute.name == "Commute")
        #expect(commute.kind == .manual)
        #expect(commute.origin == .user)
        #expect(commute.tintKey == nil)
        #expect(commute.itemCount == 0)
        let commuteAdded = fixture.store.add(
            [episode("a"), episode("b")],
            to: commute.playlistID,
            modelContext: fixture.context
        )
        let otherAdded = fixture.store.add(
            [episode("a")],
            to: other.playlistID,
            modelContext: fixture.context
        )
        #expect(commuteAdded == 2)
        #expect(otherAdded == 1)

        #expect(fixture.store.rename(commute.playlistID, to: "Morning", modelContext: fixture.context))
        #expect(!fixture.store.rename(commute.playlistID, to: "   ", modelContext: fixture.context))
        #expect(fixture.store.lastErrorMessage?.contains("Unable to rename the playlist") == true)

        let renamedContext = ModelContext(fixture.container)
        let renamedRecords = try storedPlaylists(in: renamedContext)
        #expect(fixture.store.playlists.first(where: { $0.playlistID == commute.playlistID })?.name == "Morning")
        #expect(renamedRecords.first(where: { $0.playlistID == commute.playlistID })?.name == "Morning")

        #expect(fixture.store.delete(commute.playlistID, modelContext: fixture.context))

        let deletedContext = ModelContext(fixture.container)
        #expect(fixture.store.playlists.map(\.playlistID) == [other.playlistID])
        #expect(fixture.store.itemsByPlaylistID[commute.playlistID] == nil)
        #expect(fixture.store.lastErrorMessage == nil)
        #expect(try storedPlaylists(in: deletedContext).map(\.playlistID) == [other.playlistID])
        #expect(try storedItems(in: deletedContext).map(\.playlistID) == [other.playlistID])
    }

    @Test("Adding skips existing members and copies the episode's fallbacks")
    func addDedupesAndCopiesFallbacks() throws {
        let fixture = try makeFixture()
        let playlist = try #require(
            fixture.store.create(name: "Commute", kind: .manual, modelContext: fixture.context)
        )
        let publishedAt = Date(timeIntervalSince1970: 1_775_000_000)
        let detailed = EpisodeListItemSnapshot.fixture(
            episodeID: "detailed",
            podcastID: "https://example.com/other.xml",
            podcastTitle: "Other Show",
            title: "Detailed Episode",
            publishedAt: publishedAt,
            duration: 1_800,
            audioURL: "https://example.com/detailed.mp3",
            artworkURL: "https://example.com/detailed.jpg",
            guid: "detailed"
        )

        let firstAdded = fixture.store.add(
            [episode("a"), detailed, episode("a")],
            to: playlist.playlistID,
            modelContext: fixture.context
        )
        let secondAdded = fixture.store.add(
            [detailed, episode("b")],
            to: playlist.playlistID,
            modelContext: fixture.context
        )

        #expect(firstAdded == 2)
        #expect(secondAdded == 1)
        #expect(fixture.store.itemsByPlaylistID[playlist.playlistID]?.map(\.episodeID) == ["a", "detailed", "b"])

        let storedContext = ModelContext(fixture.container)
        let records = try storedItems(in: storedContext)
        #expect(records.map(\.episodeID) == ["a", "detailed", "b"])
        #expect(Set(records.map(\.sortKey)).count == 3)
        #expect(records.allSatisfy { PlaylistSortKey.isValid($0.sortKey) })

        let stored = try #require(records.first(where: { $0.episodeID == "detailed" }))
        #expect(stored.playlistID == playlist.playlistID)
        #expect(stored.podcastID == "https://example.com/other.xml")
        #expect(stored.episodeTitle == "Detailed Episode")
        #expect(stored.podcastTitle == "Other Show")
        #expect(stored.artworkURL == "https://example.com/detailed.jpg")
        #expect(stored.audioURL == "https://example.com/detailed.mp3")
        #expect(stored.duration == 1_800)
        #expect(stored.publishedAt == publishedAt)
        #expect(!stored.itemID.isEmpty)
        #expect(!stored.dedupeUUID.isEmpty)

        let summary = try #require(fixture.store.playlists.first)
        #expect(summary.itemCount == 3)
        #expect(summary.totalDuration == 1_920)
    }

    @Test("Summaries carry item-derived figures and survive a fresh load")
    func summariesSurviveReload() throws {
        let fixture = try makeFixture()
        let playlist = try #require(
            fixture.store.create(name: "Mixed", kind: .manual, modelContext: fixture.context)
        )
        let episodes = [
            episode("one", podcastID: "https://example.com/show-1.xml", duration: 100),
            episode("two", podcastID: "https://example.com/show-1.xml", duration: nil),
            episode("three", podcastID: "https://example.com/show-2.xml", duration: 200),
            episode("four", podcastID: "https://example.com/show-3.xml", duration: 300),
            episode("five", podcastID: "https://example.com/show-4.xml", duration: 400),
            episode("six", podcastID: "https://example.com/show-5.xml", duration: 500)
        ]
        let added = fixture.store.add(episodes, to: playlist.playlistID, modelContext: fixture.context)
        #expect(added == 6)

        let summary = try #require(fixture.store.playlists.first)
        #expect(summary.itemCount == 6)
        #expect(summary.totalDuration == 1_500)
        #expect(
            summary.coverPodcastIDs == [
                "https://example.com/show-1.xml",
                "https://example.com/show-2.xml",
                "https://example.com/show-3.xml",
                "https://example.com/show-4.xml"
            ]
        )

        let reloaded = PlaylistStore()
        reloaded.load(modelContext: ModelContext(fixture.container))

        #expect(reloaded.playlists == fixture.store.playlists)
        #expect(reloaded.itemsByPlaylistID == fixture.store.itemsByPlaylistID)
        #expect(reloaded.lastErrorMessage == nil)
    }

    @Test("Removing items deletes their rows and updates the summary")
    func removeItems() throws {
        let fixture = try makeFixture()
        let playlist = try #require(
            fixture.store.create(name: "Commute", kind: .manual, modelContext: fixture.context)
        )
        let added = fixture.store.add(
            [episode("a"), episode("b"), episode("c")],
            to: playlist.playlistID,
            modelContext: fixture.context
        )
        #expect(added == 3)
        let items = fixture.store.itemsByPlaylistID[playlist.playlistID] ?? []
        let removedItemID = try #require(items.first(where: { $0.episodeID == "b" })?.itemID)

        #expect(
            fixture.store.remove(
                itemIDs: [removedItemID],
                from: playlist.playlistID,
                modelContext: fixture.context
            )
        )

        let storedContext = ModelContext(fixture.container)
        #expect(fixture.store.itemsByPlaylistID[playlist.playlistID]?.map(\.episodeID) == ["a", "c"])
        #expect(try storedItems(in: storedContext).map(\.episodeID) == ["a", "c"])
        #expect(fixture.store.playlists.first?.itemCount == 2)
        #expect(fixture.store.playlistIDs(containing: "b").isEmpty)
    }

    @Test("A single-row move rewrites exactly the moved row's key")
    func singleRowMoveRewritesOneKey() throws {
        let fixture = try makeFixture()
        let playlist = try #require(
            fixture.store.create(name: "Commute", kind: .manual, modelContext: fixture.context)
        )
        let added = fixture.store.add(
            ["a", "b", "c", "d", "e"].map { episode($0) },
            to: playlist.playlistID,
            modelContext: fixture.context
        )
        #expect(added == 5)
        let movedItemID = try #require(fixture.store.itemsByPlaylistID[playlist.playlistID]?.last?.itemID)
        let keysBefore = try storedKeysByItemID(in: fixture.container)

        #expect(
            fixture.store.move(
                fromOffsets: IndexSet(integer: 4),
                toOffset: 1,
                in: playlist.playlistID,
                modelContext: fixture.context
            )
        )

        let expectedOrder = ["a", "e", "b", "c", "d"]
        let keysAfter = try storedKeysByItemID(in: fixture.container)
        let changedItemIDs = keysAfter.filter { keysBefore[$0.key] != $0.value }.map(\.key)
        let storedContext = ModelContext(fixture.container)
        #expect(changedItemIDs == [movedItemID])
        #expect(Set(keysAfter.keys) == Set(keysBefore.keys))
        #expect(fixture.store.itemsByPlaylistID[playlist.playlistID]?.map(\.episodeID) == expectedOrder)
        #expect(try storedItems(in: storedContext).map(\.episodeID) == expectedOrder)

        let reloaded = PlaylistStore()
        reloaded.load(modelContext: ModelContext(fixture.container))
        #expect(reloaded.itemsByPlaylistID[playlist.playlistID]?.map(\.episodeID) == expectedOrder)
    }

    @Test("A multi-row move rewrites only the moved rows' keys")
    func multiRowMoveRewritesMovedKeys() throws {
        let fixture = try makeFixture()
        let playlist = try #require(
            fixture.store.create(name: "Commute", kind: .manual, modelContext: fixture.context)
        )
        let added = fixture.store.add(
            ["a", "b", "c", "d", "e"].map { episode($0) },
            to: playlist.playlistID,
            modelContext: fixture.context
        )
        #expect(added == 5)
        let items = fixture.store.itemsByPlaylistID[playlist.playlistID] ?? []
        let movedItemIDs = Set([items[0].itemID, items[2].itemID])
        let keysBefore = try storedKeysByItemID(in: fixture.container)

        #expect(
            fixture.store.move(
                fromOffsets: IndexSet([0, 2]),
                toOffset: 5,
                in: playlist.playlistID,
                modelContext: fixture.context
            )
        )

        let expectedOrder = ["b", "d", "e", "a", "c"]
        let keysAfter = try storedKeysByItemID(in: fixture.container)
        let changedItemIDs = Set(keysAfter.filter { keysBefore[$0.key] != $0.value }.map(\.key))
        let storedContext = ModelContext(fixture.container)
        #expect(changedItemIDs == movedItemIDs)
        #expect(fixture.store.itemsByPlaylistID[playlist.playlistID]?.map(\.episodeID) == expectedOrder)
        #expect(try storedItems(in: storedContext).map(\.episodeID) == expectedOrder)
    }

    @Test("A move renumbers the whole playlist in one save when a key is too long")
    func moveRenumbersOverlongKeys() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let longKey = String(repeating: "1", count: 69) + "2"
        #expect(longKey.count == 70)
        #expect(PlaylistSortKey.isValid(longKey))
        #expect(PlaylistSortKey.needsRenumbering(longKey))
        context.insert(PlaylistRecord(playlistID: "renumber", name: "Renumber"))
        for (index, sortKey) in ["1", longKey, "2"].enumerated() {
            context.insert(
                PlaylistItemRecord(
                    itemID: "renumber-item-\(index)",
                    playlistID: "renumber",
                    episodeID: "episode-\(index)",
                    podcastID: "https://example.com/feed.xml",
                    sortKey: sortKey,
                    episodeTitle: "Episode \(index)",
                    podcastTitle: "Example Show"
                )
            )
        }
        try context.save()
        let probe = PlaylistStoreProbe()
        let store = PlaylistStore(saveModelContext: probe.save, now: probe.nextDate)
        store.load(modelContext: context)
        #expect(store.itemsByPlaylistID["renumber"]?.map(\.episodeID) == ["episode-0", "episode-1", "episode-2"])

        #expect(
            store.move(
                fromOffsets: IndexSet(integer: 2),
                toOffset: 0,
                in: "renumber",
                modelContext: context
            )
        )

        let storedContext = ModelContext(container)
        let records = try storedItems(in: storedContext)
        #expect(probe.saveCount == 1)
        #expect(records.map(\.episodeID) == ["episode-2", "episode-0", "episode-1"])
        #expect(records.map(\.sortKey) == PlaylistSortKey.renumbered(count: 3))
        #expect(!records.contains(where: { PlaylistSortKey.needsRenumbering($0.sortKey) }))
        #expect(store.itemsByPlaylistID["renumber"]?.map(\.sortKey) == records.map(\.sortKey))
    }

    @Test("Adding after rows with unusable keys renumbers them first")
    func addRenumbersUnusableKeys() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let addedAt = Date(timeIntervalSince1970: 1_775_000_000)
        context.insert(PlaylistRecord(playlistID: "legacy", name: "Legacy"))
        for index in 0..<2 {
            context.insert(
                PlaylistItemRecord(
                    itemID: "legacy-item-\(index)",
                    playlistID: "legacy",
                    episodeID: "legacy-episode-\(index)",
                    podcastID: "https://example.com/feed.xml",
                    sortKey: "",
                    addedAt: addedAt.addingTimeInterval(Double(index)),
                    episodeTitle: "Legacy Episode \(index)",
                    podcastTitle: "Example Show"
                )
            )
        }
        try context.save()
        let store = PlaylistStore()
        store.load(modelContext: context)

        let added = store.add([episode("fresh")], to: "legacy", modelContext: context)

        let storedContext = ModelContext(container)
        let records = try storedItems(in: storedContext)
        #expect(added == 1)
        #expect(records.map(\.episodeID) == ["legacy-episode-0", "legacy-episode-1", "fresh"])
        #expect(records.allSatisfy { PlaylistSortKey.isValid($0.sortKey) })
        #expect(records.map(\.sortKey) == records.map(\.sortKey).sorted())
        #expect(Set(records.map(\.sortKey)).count == 3)
    }

    @Test("A failed create leaves memory and storage unchanged")
    func createRollsBack() throws {
        let fixture = try makeFixture()
        let existing = try #require(
            fixture.store.create(name: "Existing", kind: .manual, modelContext: fixture.context)
        )
        fixture.probe.failsSaves = true

        let created = fixture.store.create(name: "New", kind: .smart, modelContext: fixture.context)

        let storedContext = ModelContext(fixture.container)
        #expect(created == nil)
        #expect(fixture.store.playlists.map(\.playlistID) == [existing.playlistID])
        #expect(try storedPlaylists(in: storedContext).map(\.playlistID) == [existing.playlistID])
        #expect(try fixture.context.fetch(FetchDescriptor<PlaylistRecord>()).count == 1)
        #expect(fixture.store.lastErrorMessage?.contains("Unable to create the playlist") == true)
    }

    @Test("A failed add leaves memory and storage unchanged")
    func addRollsBack() throws {
        let fixture = try makeFixture()
        let playlist = try #require(
            fixture.store.create(name: "Commute", kind: .manual, modelContext: fixture.context)
        )
        let firstAdded = fixture.store.add([episode("a")], to: playlist.playlistID, modelContext: fixture.context)
        #expect(firstAdded == 1)
        let summaryBefore = fixture.store.playlists
        let itemsBefore = fixture.store.itemsByPlaylistID
        fixture.probe.failsSaves = true

        let added = fixture.store.add([episode("b")], to: playlist.playlistID, modelContext: fixture.context)

        let storedContext = ModelContext(fixture.container)
        #expect(added == 0)
        #expect(fixture.store.playlists == summaryBefore)
        #expect(fixture.store.itemsByPlaylistID == itemsBefore)
        #expect(try storedItems(in: storedContext).map(\.episodeID) == ["a"])
        #expect(try storedPlaylists(in: storedContext).first?.updatedAt == summaryBefore.first?.updatedAt)
        #expect(try fixture.context.fetch(FetchDescriptor<PlaylistItemRecord>()).count == 1)
        #expect(fixture.store.lastErrorMessage?.contains("Unable to add the episode to the playlist") == true)
    }

    @Test("A failed remove leaves memory and storage unchanged")
    func removeRollsBack() throws {
        let fixture = try makeFixture()
        let playlist = try #require(
            fixture.store.create(name: "Commute", kind: .manual, modelContext: fixture.context)
        )
        let added = fixture.store.add(
            ["a", "b", "c"].map { episode($0) },
            to: playlist.playlistID,
            modelContext: fixture.context
        )
        #expect(added == 3)
        let summaryBefore = fixture.store.playlists
        let itemsBefore = fixture.store.itemsByPlaylistID
        let keysBefore = try storedKeysByItemID(in: fixture.container)
        let removedItemID = try #require(itemsBefore[playlist.playlistID]?[1].itemID)
        fixture.probe.failsSaves = true

        let removed = fixture.store.remove(
            itemIDs: [removedItemID],
            from: playlist.playlistID,
            modelContext: fixture.context
        )

        let storedContext = ModelContext(fixture.container)
        #expect(!removed)
        #expect(fixture.store.playlists == summaryBefore)
        #expect(fixture.store.itemsByPlaylistID == itemsBefore)
        #expect(try storedItems(in: storedContext).map(\.episodeID) == ["a", "b", "c"])
        #expect(try storedKeysByItemID(in: fixture.container) == keysBefore)
        #expect(try fixture.context.fetch(FetchDescriptor<PlaylistItemRecord>()).count == 3)
        #expect(fixture.store.lastErrorMessage?.contains("Unable to remove the episode from the playlist") == true)
    }

    @Test("A failed delete leaves memory and storage unchanged")
    func deleteRollsBack() throws {
        let fixture = try makeFixture()
        let playlist = try #require(
            fixture.store.create(name: "Commute", kind: .manual, modelContext: fixture.context)
        )
        let added = fixture.store.add(
            ["a", "b"].map { episode($0) },
            to: playlist.playlistID,
            modelContext: fixture.context
        )
        #expect(added == 2)
        let summaryBefore = fixture.store.playlists
        let itemsBefore = fixture.store.itemsByPlaylistID
        fixture.probe.failsSaves = true

        let deleted = fixture.store.delete(playlist.playlistID, modelContext: fixture.context)

        let storedContext = ModelContext(fixture.container)
        #expect(!deleted)
        #expect(fixture.store.playlists == summaryBefore)
        #expect(fixture.store.itemsByPlaylistID == itemsBefore)
        #expect(try storedPlaylists(in: storedContext).map(\.playlistID) == [playlist.playlistID])
        #expect(try storedItems(in: storedContext).map(\.episodeID) == ["a", "b"])
        #expect(try fixture.context.fetch(FetchDescriptor<PlaylistRecord>()).count == 1)
        #expect(try fixture.context.fetch(FetchDescriptor<PlaylistItemRecord>()).count == 2)
        #expect(fixture.store.lastErrorMessage?.contains("Unable to delete the playlist") == true)
    }

    @Test("An identity re-key is published only once its save commits and skips an unloaded store")
    func identityRekeyPublishesOnCommit() throws {
        let successorPodcastID = "https://example.com/new.xml"
        let unloaded = PlaylistStore()
        var unloadedChanges = 0
        unloaded.onPlaylistsChanged = { unloadedChanges += 1 }
        let unloadedContext = ModelContext(try OpenCastModelContainerFactory.make(inMemory: true))

        try unloaded.migrateEpisodeSidecars(
            from: "old",
            to: "new",
            canonicalPodcastID: successorPodcastID,
            modelContext: unloadedContext
        )
        unloaded.finishEpisodeSidecarMigration(committed: true)

        #expect(unloaded.playlists.isEmpty)
        #expect(unloaded.itemsByPlaylistID.isEmpty)
        #expect(unloadedChanges == 0)

        let fixture = try makeFixture()
        let departedOnly = try #require(
            fixture.store.create(name: "Departed Only", kind: .manual, modelContext: fixture.context)
        )
        let both = try #require(
            fixture.store.create(name: "Both", kind: .manual, modelContext: fixture.context)
        )
        let departedAdded = fixture.store.add(
            [episode("a"), episode("old")],
            to: departedOnly.playlistID,
            modelContext: fixture.context
        )
        let bothAdded = fixture.store.add(
            [episode("old"), episode("new")],
            to: both.playlistID,
            modelContext: fixture.context
        )
        #expect(departedAdded == 2)
        #expect(bothAdded == 2)
        let keysBefore = try storedKeysByItemID(in: fixture.container)
        let departedItemID = try #require(fixture.store.itemsByPlaylistID[departedOnly.playlistID]?.last?.itemID)
        let playlistsBefore = fixture.store.playlists
        let itemsBefore = fixture.store.itemsByPlaylistID
        let saveCountBefore = fixture.probe.saveCount
        var changeCount = 0
        fixture.store.onPlaylistsChanged = { changeCount += 1 }

        // A save that fails leaves the loaded state exactly as it was.
        try fixture.store.migrateEpisodeSidecars(
            from: "old",
            to: "new",
            canonicalPodcastID: successorPodcastID,
            modelContext: fixture.context
        )
        #expect(fixture.store.itemsByPlaylistID == itemsBefore)
        #expect(fixture.store.playlists == playlistsBefore)
        #expect(changeCount == 0)
        fixture.store.finishEpisodeSidecarMigration(committed: false)

        #expect(fixture.store.itemsByPlaylistID == itemsBefore)
        #expect(fixture.store.playlists == playlistsBefore)
        #expect(fixture.store.playlistIDs(containing: "old") == [departedOnly.playlistID, both.playlistID])
        #expect(changeCount == 0)

        // A committed save publishes the re-key once.
        try fixture.store.migrateEpisodeSidecars(
            from: "old",
            to: "new",
            canonicalPodcastID: successorPodcastID,
            modelContext: fixture.context
        )
        #expect(fixture.store.itemsByPlaylistID == itemsBefore)
        #expect(changeCount == 0)
        fixture.store.finishEpisodeSidecarMigration(committed: true)

        #expect(changeCount == 1)
        #expect(fixture.probe.saveCount == saveCountBefore)
        let departedItems = fixture.store.itemsByPlaylistID[departedOnly.playlistID] ?? []
        #expect(departedItems.map(\.episodeID) == ["a", "new"])
        #expect(departedItems.last?.itemID == departedItemID)
        #expect(departedItems.last?.podcastID == successorPodcastID)
        #expect(departedItems.last?.sortKey == keysBefore[departedItemID])
        #expect(fixture.store.itemsByPlaylistID[both.playlistID]?.map(\.episodeID) == ["new"])
        let departedSummary = try #require(
            fixture.store.playlists.first(where: { $0.playlistID == departedOnly.playlistID })
        )
        let bothSummary = try #require(fixture.store.playlists.first(where: { $0.playlistID == both.playlistID }))
        #expect(departedSummary.itemCount == 2)
        #expect(departedSummary.coverPodcastIDs == ["https://example.com/feed.xml", successorPodcastID])
        #expect(bothSummary.itemCount == 1)
        #expect(bothSummary.totalDuration == 60)
        #expect(fixture.store.playlists.map(\.updatedAt) == playlistsBefore.map(\.updatedAt))
        #expect(fixture.store.playlistIDs(containing: "old").isEmpty)
        #expect(fixture.store.playlistIDs(containing: "new") == [departedOnly.playlistID, both.playlistID])
        // Rows belong to the applier; the memory pass leaves them alone.
        #expect(
            try storedItems(in: ModelContext(fixture.container)).map(\.episodeID).sorted()
                == ["a", "new", "old", "old"]
        )

        // Nothing staged: a stray completion is a no-op, and a re-key that
        // changes nothing stays quiet.
        fixture.store.finishEpisodeSidecarMigration(committed: true)
        try fixture.store.migrateEpisodeSidecars(
            from: "old",
            to: "new",
            canonicalPodcastID: successorPodcastID,
            modelContext: fixture.context
        )
        fixture.store.finishEpisodeSidecarMigration(committed: true)

        #expect(changeCount == 1)
    }

    @Test("A failed move leaves memory, keys and storage unchanged")
    func moveRollsBack() throws {
        let fixture = try makeFixture()
        let playlist = try #require(
            fixture.store.create(name: "Commute", kind: .manual, modelContext: fixture.context)
        )
        let added = fixture.store.add(
            ["a", "b", "c"].map { episode($0) },
            to: playlist.playlistID,
            modelContext: fixture.context
        )
        #expect(added == 3)
        let summaryBefore = fixture.store.playlists
        let itemsBefore = fixture.store.itemsByPlaylistID
        let keysBefore = try storedKeysByItemID(in: fixture.container)
        fixture.probe.failsSaves = true

        #expect(
            !fixture.store.move(
                fromOffsets: IndexSet(integer: 0),
                toOffset: 3,
                in: playlist.playlistID,
                modelContext: fixture.context
            )
        )

        let contextKeys = try storedItems(in: fixture.context).map(\.sortKey)
        #expect(fixture.store.playlists == summaryBefore)
        #expect(fixture.store.itemsByPlaylistID == itemsBefore)
        #expect(try storedKeysByItemID(in: fixture.container) == keysBefore)
        #expect(contextKeys == itemsBefore[playlist.playlistID]?.map(\.sortKey))
        #expect(fixture.store.lastErrorMessage?.contains("Unable to reorder the playlist") == true)
    }

    @Test("A failed playlist update keeps the loaded summary")
    func updateRollsBack() throws {
        let fixture = try makeFixture()
        let playlist = try #require(
            fixture.store.create(name: "Commute", kind: .manual, modelContext: fixture.context)
        )
        fixture.probe.failsSaves = true

        #expect(!fixture.store.setHidesPlayed(true, for: playlist.playlistID, modelContext: fixture.context))

        let storedContext = ModelContext(fixture.container)
        #expect(fixture.store.playlists == [playlist])
        #expect(try storedPlaylists(in: storedContext).first?.hidesPlayed == false)
        #expect(fixture.store.lastErrorMessage?.contains("Unable to update Hide Played") == true)
    }

    @Test("Membership lookup lists every playlist holding an episode")
    func playlistIDsContainingEpisode() throws {
        let fixture = try makeFixture()
        let first = try #require(
            fixture.store.create(name: "First", kind: .manual, modelContext: fixture.context)
        )
        let second = try #require(
            fixture.store.create(name: "Second", kind: .manual, modelContext: fixture.context)
        )
        let firstAdded = fixture.store.add(
            [episode("a"), episode("b")],
            to: first.playlistID,
            modelContext: fixture.context
        )
        let secondAdded = fixture.store.add([episode("b")], to: second.playlistID, modelContext: fixture.context)
        #expect(firstAdded == 2)
        #expect(secondAdded == 1)

        #expect(fixture.store.playlistIDs(containing: "b") == [first.playlistID, second.playlistID])
        #expect(fixture.store.playlistIDs(containing: "a") == [first.playlistID])
        #expect(fixture.store.playlistIDs(containing: "missing").isEmpty)
    }

    @Test("Load keeps rows whose episode no longer resolves")
    func loadKeepsUnresolvedRows() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        context.insert(PlaylistRecord(playlistID: "kept", name: "Kept"))
        context.insert(
            PlaylistItemRecord(
                itemID: "departed-item",
                playlistID: "kept",
                episodeID: "departed",
                podcastID: "https://example.com/unsubscribed.xml",
                sortKey: "i",
                episodeTitle: "Departed Episode",
                podcastTitle: "Departed Show",
                duration: 900
            )
        )
        context.insert(
            PlaylistItemRecord(
                itemID: "present-item",
                playlistID: "kept",
                episodeID: "present",
                podcastID: "https://example.com/feed.xml",
                sortKey: "r",
                episodeTitle: "Present Episode",
                podcastTitle: "Example Show"
            )
        )
        try context.save()
        let store = PlaylistStore()

        store.load(modelContext: context)

        let resolved = store.resolvedItems(in: "kept") { episodeID in
            episodeID == "present" ? episode(episodeID) : nil
        }
        let storedContext = ModelContext(container)
        #expect(resolved.map(\.id) == ["departed-item", "present-item"])
        #expect(resolved.map(\.isResolved) == [false, true])
        #expect(resolved.first?.item.episodeTitle == "Departed Episode")
        #expect(resolved.first?.item.podcastTitle == "Departed Show")
        #expect(resolved.first?.item.duration == 900)
        #expect(store.playlists.first?.itemCount == 2)
        #expect(try storedItems(in: storedContext).count == 2)
        #expect(store.lastErrorMessage == nil)
    }

    @Test("Counts treat played episodes as done")
    func countsUsePlayedState() throws {
        let fixture = try makeFixture()
        let playlist = try #require(
            fixture.store.create(name: "Commute", kind: .manual, modelContext: fixture.context)
        )
        let added = fixture.store.add(
            [episode("a", duration: 60), episode("b", duration: 120), episode("c", duration: nil)],
            to: playlist.playlistID,
            modelContext: fixture.context
        )
        #expect(added == 3)

        let counts = fixture.store.counts(for: playlist.playlistID) { $0 == "b" }
        let missingCounts = fixture.store.counts(for: "missing") { _ in false }

        #expect(counts == PlaylistCounts(itemCount: 3, unplayedCount: 2, remainingDuration: 60))
        #expect(missingCounts == PlaylistCounts(itemCount: 0, unplayedCount: 0, remainingDuration: 0))
    }

    @Test("Sort order switches between name and most recently updated")
    func sortOrders() throws {
        let fixture = try makeFixture()
        let beta = try #require(fixture.store.create(name: "Beta", kind: .manual, modelContext: fixture.context))
        _ = try #require(fixture.store.create(name: "alpha", kind: .manual, modelContext: fixture.context))
        _ = try #require(fixture.store.create(name: "Gamma", kind: .manual, modelContext: fixture.context))

        #expect(fixture.store.sortOrder == .recentlyUpdated)
        #expect(fixture.store.playlists.map(\.name) == ["Gamma", "alpha", "Beta"])

        fixture.store.sortOrder = .name
        #expect(fixture.store.playlists.map(\.name) == ["alpha", "Beta", "Gamma"])

        #expect(fixture.store.setHidesPlayed(true, for: beta.playlistID, modelContext: fixture.context))
        #expect(fixture.store.playlists.map(\.name) == ["alpha", "Beta", "Gamma"])

        fixture.store.sortOrder = .recentlyUpdated
        #expect(fixture.store.playlists.map(\.name) == ["Beta", "Gamma", "alpha"])
    }

    @Test("Every mutation bumps the playlist's updatedAt")
    func mutationsBumpUpdatedAt() throws {
        let fixture = try makeFixture()
        let playlist = try #require(
            fixture.store.create(name: "Commute", kind: .smart, modelContext: fixture.context)
        )
        let manual = try #require(
            fixture.store.create(name: "Manual", kind: .manual, modelContext: fixture.context)
        )
        var updatedAt = playlist.updatedAt

        #expect(fixture.store.rename(playlist.playlistID, to: "Evening", modelContext: fixture.context))
        updatedAt = try expectBumpedUpdatedAt(playlist.playlistID, since: updatedAt, fixture: fixture)
        #expect(fixture.store.setHidesPlayed(true, for: playlist.playlistID, modelContext: fixture.context))
        updatedAt = try expectBumpedUpdatedAt(playlist.playlistID, since: updatedAt, fixture: fixture)
        var playedRule = PlaylistRule.default
        playedRule.status = .played
        let didSetRule = fixture.store.setRule(playedRule, for: playlist.playlistID, modelContext: fixture.context)
        #expect(didSetRule)
        _ = try expectBumpedUpdatedAt(playlist.playlistID, since: updatedAt, fixture: fixture)

        updatedAt = manual.updatedAt
        let added = fixture.store.add(
            [episode("a"), episode("b")],
            to: manual.playlistID,
            modelContext: fixture.context
        )
        #expect(added == 2)
        updatedAt = try expectBumpedUpdatedAt(manual.playlistID, since: updatedAt, fixture: fixture)
        #expect(
            fixture.store.move(
                fromOffsets: IndexSet(integer: 1),
                toOffset: 0,
                in: manual.playlistID,
                modelContext: fixture.context
            )
        )
        updatedAt = try expectBumpedUpdatedAt(manual.playlistID, since: updatedAt, fixture: fixture)
        #expect(fixture.store.itemsByPlaylistID[manual.playlistID]?.first?.updatedAt == updatedAt)
        let removedItemID = try #require(fixture.store.itemsByPlaylistID[manual.playlistID]?.first?.itemID)
        #expect(
            fixture.store.remove(
                itemIDs: [removedItemID],
                from: manual.playlistID,
                modelContext: fixture.context
            )
        )
        _ = try expectBumpedUpdatedAt(manual.playlistID, since: updatedAt, fixture: fixture)

        let storedContext = ModelContext(fixture.container)
        let storedRecords = try storedPlaylists(in: storedContext)
        let storedSmart = try #require(storedRecords.first(where: { $0.playlistID == playlist.playlistID }))
        #expect(storedSmart.name == "Evening")
        #expect(storedSmart.hidesPlayed)
        #expect(storedSmart.ruleJSON == playedRule.encodedJSON())
    }

    @Test("Smart playlists take the least-used tint and reject manual adds")
    func smartPlaylistsTakeLeastUsedTint() throws {
        let fixture = try makeFixture()
        let first = try #require(fixture.store.create(name: "One", kind: .smart, modelContext: fixture.context))
        let second = try #require(fixture.store.create(name: "Two", kind: .smart, modelContext: fixture.context))
        let manual = try #require(fixture.store.create(name: "Manual", kind: .manual, modelContext: fixture.context))
        let third = try #require(
            fixture.store.create(name: "Three", kind: .smart, origin: .ai, modelContext: fixture.context)
        )

        #expect(
            [first, second, third].map(\.tintKey) == [
                PlaylistTint.red.rawValue,
                PlaylistTint.orange.rawValue,
                PlaylistTint.yellow.rawValue
            ]
        )
        #expect(manual.tintKey == nil)
        #expect(first.ruleJSON == PlaylistRule.default.encodedJSON())
        #expect(first.rule == .default)
        #expect(third.origin == .ai)

        #expect(fixture.store.delete(second.playlistID, modelContext: fixture.context))
        let fourth = try #require(fixture.store.create(name: "Four", kind: .smart, modelContext: fixture.context))
        #expect(fourth.tintKey == PlaylistTint.orange.rawValue)

        let storedContext = ModelContext(fixture.container)
        let storedRecords = try storedPlaylists(in: storedContext)
        let storedFourth = try #require(storedRecords.first(where: { $0.playlistID == fourth.playlistID }))
        #expect(storedFourth.kind == .smart)
        #expect(storedFourth.tintKey == PlaylistTint.orange.rawValue)

        let added = fixture.store.add([episode("a")], to: first.playlistID, modelContext: fixture.context)
        #expect(added == 0)
        #expect(fixture.store.lastErrorMessage?.contains("smart playlists") == true)
        #expect(try storedItems(in: storedContext).isEmpty)
    }

    @Test("A smart create stores the default rule and the first eight take distinct tints in case order")
    func smartCreateStoresDefaultRuleAndDistinctTints() throws {
        let fixture = try makeFixture()
        var created: [PlaylistSummary] = []
        for index in 1 ... PlaylistTint.allCases.count {
            let summary = try #require(
                fixture.store.create(name: "Smart \(index)", kind: .smart, modelContext: fixture.context)
            )
            created.append(summary)
        }
        let ninth = try #require(fixture.store.create(name: "Smart 9", kind: .smart, modelContext: fixture.context))

        #expect(created.map(\.tintKey) == PlaylistTint.allCases.map(\.rawValue))
        #expect(created.compactMap(\.tint) == PlaylistTint.allCases)
        #expect(ninth.tint == .red)
        #expect(created.allSatisfy { $0.ruleJSON == PlaylistRule.default.encodedJSON() })
        #expect(created.allSatisfy { $0.rule == .default && !$0.hasUnreadableRule })
        let storedRecords = try storedPlaylists(in: ModelContext(fixture.container))
        #expect(storedRecords.count == 9)
        #expect(storedRecords.allSatisfy { $0.ruleJSON == PlaylistRule.default.encodedJSON() })
        let reloaded = PlaylistStore()
        reloaded.load(modelContext: ModelContext(fixture.container))
        #expect(reloaded.playlists.count == 9)
        #expect(reloaded.playlists.allSatisfy { $0.rule == .default })
    }

    @Test("A smart create stores the given rule normalized, and a manual create stores no rule")
    func createStoresGivenRuleForSmartOnly() throws {
        let fixture = try makeFixture()
        let rule = PlaylistRule(podcastIDs: [], status: .played, maximumAgeDays: -1, sortOrder: .longestFirst, limit: 50)
        let smart = try #require(
            fixture.store.create(name: "Smart", kind: .smart, rule: rule, modelContext: fixture.context)
        )
        let manual = try #require(
            fixture.store.create(name: "Manual", kind: .manual, rule: rule, modelContext: fixture.context)
        )

        #expect(smart.rule == rule.normalized())
        #expect(smart.rule?.podcastIDs == nil)
        #expect(smart.rule?.maximumAgeDays == nil)
        #expect(smart.rule?.status == .played)
        #expect(smart.ruleJSON == rule.normalized().encodedJSON())
        #expect(manual.rule == nil)
        #expect(manual.ruleJSON == nil)
        #expect(manual.tint == nil)
        #expect(!manual.hasUnreadableRule)
        let storedRecords = try storedPlaylists(in: ModelContext(fixture.container))
        #expect(storedRecords.map(\.ruleJSON) == [rule.normalized().encodedJSON(), nil])
    }

    @Test("Setting a rule stores its canonical form, bumps updatedAt, and saves and notifies once")
    func setRulePersistsCanonicalRule() throws {
        let fixture = try makeFixture()
        let playlist = try #require(
            fixture.store.create(name: "Fresh", kind: .smart, modelContext: fixture.context)
        )
        let saveCount = fixture.probe.saveCount
        var changeCount = 0
        fixture.store.onPlaylistsChanged = { changeCount += 1 }
        let rule = PlaylistRule(
            podcastIDs: ["https://example.com/b.xml", "https://example.com/a.xml", "https://example.com/b.xml"],
            status: .downloaded,
            maximumMinutes: 45,
            sortOrder: .shortestFirst,
            limit: 0
        )
        let expected = rule.normalized()

        let didSetRule = fixture.store.setRule(rule, for: playlist.playlistID, modelContext: fixture.context)

        #expect(didSetRule)
        #expect(expected.podcastIDs == ["https://example.com/a.xml", "https://example.com/b.xml"])
        #expect(expected.status == .all)
        #expect(expected.downloadedOnly)
        #expect(expected.limit == nil)
        let summary = try #require(fixture.store.playlists.first(where: { $0.playlistID == playlist.playlistID }))
        #expect(summary.rule == expected)
        #expect(summary.ruleJSON == expected.encodedJSON())
        _ = try expectBumpedUpdatedAt(playlist.playlistID, since: playlist.updatedAt, fixture: fixture)
        #expect(fixture.probe.saveCount == saveCount + 1)
        #expect(changeCount == 1)
        #expect(fixture.store.lastErrorMessage == nil)
        let stored = try #require(try storedPlaylists(in: ModelContext(fixture.container)).first)
        #expect(stored.ruleJSON == expected.encodedJSON())
        let reloaded = PlaylistStore()
        reloaded.load(modelContext: ModelContext(fixture.container))
        #expect(reloaded.playlists.first?.rule == expected)
    }

    @Test("Setting an identical rule, or one that normalizes to it, saves nothing and does not notify")
    func setIdenticalRuleIsNoOp() throws {
        let fixture = try makeFixture()
        let playlist = try #require(
            fixture.store.create(name: "Fresh", kind: .smart, modelContext: fixture.context)
        )
        let saveCount = fixture.probe.saveCount
        var changeCount = 0
        fixture.store.onPlaylistsChanged = { changeCount += 1 }
        var equivalent = PlaylistRule.default
        equivalent.podcastIDs = []

        let setDefault = fixture.store.setRule(.default, for: playlist.playlistID, modelContext: fixture.context)
        let setEquivalent = fixture.store.setRule(equivalent, for: playlist.playlistID, modelContext: fixture.context)

        #expect(setDefault)
        #expect(setEquivalent)
        #expect(fixture.probe.saveCount == saveCount)
        #expect(changeCount == 0)
        #expect(fixture.store.playlists == [playlist])
        #expect(fixture.store.lastErrorMessage == nil)
    }

    @Test("Re-picking the rule a smart row without rule JSON already reads as saves nothing")
    func setRuleOnNilJSONRowIsNoOp() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let updatedAt = Date(timeIntervalSince1970: 1_775_000_000)
        context.insert(
            PlaylistRecord(
                playlistID: "smart-nil",
                name: "Smart",
                kind: .smart,
                ruleJSON: nil,
                createdAt: updatedAt,
                updatedAt: updatedAt
            )
        )
        try context.save()
        var saveCount = 0
        let store = PlaylistStore(saveModelContext: { modelContext in
            saveCount += 1
            try modelContext.save()
        })
        store.load(modelContext: context)

        #expect(store.setRule(.default, for: "smart-nil", modelContext: context))
        #expect(saveCount == 0)
        #expect(store.playlists.first?.updatedAt == updatedAt)
        #expect(store.playlists.first?.ruleJSON == nil)
        #expect(store.lastErrorMessage == nil)
    }

    @Test("Setting a rule refuses a manual playlist and a missing one without saving")
    func setRuleRefusesManualAndMissing() throws {
        let fixture = try makeFixture()
        let manual = try #require(
            fixture.store.create(name: "Manual", kind: .manual, modelContext: fixture.context)
        )
        let saveCount = fixture.probe.saveCount
        var changeCount = 0
        fixture.store.onPlaylistsChanged = { changeCount += 1 }

        let setManual = fixture.store.setRule(.default, for: manual.playlistID, modelContext: fixture.context)

        #expect(!setManual)
        #expect(fixture.store.lastErrorMessage == "Unable to update the playlist rules.")
        #expect(fixture.store.playlists == [manual])
        #expect(try storedPlaylists(in: ModelContext(fixture.container)).first?.ruleJSON == nil)

        let setMissing = fixture.store.setRule(.default, for: "missing", modelContext: fixture.context)

        #expect(!setMissing)
        #expect(
            fixture.store.lastErrorMessage
                == "Unable to update the playlist rules because the playlist no longer exists."
        )
        #expect(fixture.probe.saveCount == saveCount)
        #expect(changeCount == 0)
    }

    @Test("A newer-version rule loads as unreadable, refuses a new rule, and survives a rename verbatim")
    func unreadableRuleIsNeverOverwritten() throws {
        let fixture = try makeFixture()
        let newerRuleJSON = #"{"version":2,"clauses":[]}"#
        fixture.context.insert(
            PlaylistRecord(
                playlistID: "newer",
                name: "Newer",
                kind: .smart,
                ruleJSON: newerRuleJSON,
                tintKey: PlaylistTint.teal.rawValue
            )
        )
        try fixture.context.save()
        fixture.store.load(modelContext: fixture.context)
        let loaded = try #require(fixture.store.playlists.first)
        var changeCount = 0
        fixture.store.onPlaylistsChanged = { changeCount += 1 }

        #expect(loaded.rule == nil)
        #expect(loaded.hasUnreadableRule)
        #expect(loaded.ruleJSON == newerRuleJSON)
        #expect(loaded.tint == .teal)

        let didSetRule = fixture.store.setRule(.default, for: "newer", modelContext: fixture.context)

        #expect(!didSetRule)
        #expect(fixture.store.lastErrorMessage == "These rules need a newer version of the app.")
        #expect(fixture.probe.saveCount == 0)
        #expect(changeCount == 0)

        #expect(fixture.store.rename("newer", to: "Renamed", modelContext: fixture.context))

        let stored = try #require(try storedPlaylists(in: ModelContext(fixture.container)).first)
        #expect(stored.name == "Renamed")
        #expect(stored.ruleJSON == newerRuleJSON)
        #expect(fixture.store.playlists.first?.hasUnreadableRule == true)
    }

    @Test("A smart row without rule JSON reads as the default rule, malformed JSON is unreadable, and unknown tints read blue")
    func summaryRuleAndTintResolution() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let createdAt = Date(timeIntervalSince1970: 1_775_000_000)
        let rows: [(playlistID: String, kind: PlaylistKind, ruleJSON: String?, tintKey: String?)] = [
            ("smart-nil", .smart, nil, nil),
            ("smart-malformed", .smart, "{", PlaylistTint.indigo.rawValue),
            ("smart-bare", .smart, #"{"version":1}"#, "sparkly"),
            ("manual", .manual, nil, PlaylistTint.red.rawValue)
        ]
        for (index, row) in rows.enumerated() {
            let timestamp = createdAt.addingTimeInterval(Double(index))
            context.insert(
                PlaylistRecord(
                    playlistID: row.playlistID,
                    name: row.playlistID,
                    kind: row.kind,
                    ruleJSON: row.ruleJSON,
                    tintKey: row.tintKey,
                    createdAt: timestamp,
                    updatedAt: timestamp
                )
            )
        }
        try context.save()
        let store = PlaylistStore()

        store.load(modelContext: context)

        let summaries = Dictionary(uniqueKeysWithValues: store.playlists.map { ($0.playlistID, $0) })
        let unset = try #require(summaries["smart-nil"])
        #expect(unset.rule == .default)
        #expect(!unset.hasUnreadableRule)
        #expect(unset.tint == .blue)
        let malformed = try #require(summaries["smart-malformed"])
        #expect(malformed.rule == nil)
        #expect(malformed.hasUnreadableRule)
        #expect(malformed.tint == .indigo)
        let bare = try #require(summaries["smart-bare"])
        #expect(bare.rule == PlaylistRule())
        #expect(!bare.hasUnreadableRule)
        #expect(bare.tint == .blue)
        let manual = try #require(summaries["manual"])
        #expect(manual.rule == nil)
        #expect(!manual.hasUnreadableRule)
        #expect(manual.tint == nil)
        #expect(PlaylistTint.resolved(nil) == .blue)
        #expect(PlaylistTint.resolved("sparkly") == .blue)
        #expect(PlaylistTint.allCases.allSatisfy { PlaylistTint.resolved($0.rawValue) == $0 })
    }

    @Test("Deleting a playlist drops only its memoized evaluation, and a failed delete keeps it")
    func deleteDropsMemoizedEvaluation() throws {
        let fixture = try makeFixture()
        let first = try #require(fixture.store.create(name: "First", kind: .smart, modelContext: fixture.context))
        let second = try #require(fixture.store.create(name: "Second", kind: .smart, modelContext: fixture.context))
        let cache = fixture.store.smartEvaluations
        let key = memoKey()
        _ = cache.evaluation(for: first.playlistID, key: key) { [episode("a")] }
        _ = cache.evaluation(for: second.playlistID, key: key) { [episode("b")] }
        #expect(cache.computeCount == 2)

        fixture.probe.failsSaves = true
        #expect(!fixture.store.delete(first.playlistID, modelContext: fixture.context))

        let kept = cache.evaluation(for: first.playlistID, key: key) { [] }
        #expect(kept.episodes.map(\.episodeID) == ["a"])
        #expect(cache.computeCount == 2)

        fixture.probe.failsSaves = false
        #expect(fixture.store.delete(first.playlistID, modelContext: fixture.context))

        let recomputed = cache.evaluation(for: first.playlistID, key: key) { [] }
        #expect(recomputed == .empty)
        #expect(cache.computeCount == 3)
        let untouched = cache.evaluation(for: second.playlistID, key: key) { [] }
        #expect(untouched.episodes.map(\.episodeID) == ["b"])
        #expect(cache.computeCount == 3)
    }

    @Test("A data nuke clears every memoized evaluation")
    func nukeClearsMemoizedEvaluations() throws {
        let fixture = try makeFixture()
        let first = try #require(fixture.store.create(name: "First", kind: .smart, modelContext: fixture.context))
        let second = try #require(fixture.store.create(name: "Second", kind: .smart, modelContext: fixture.context))
        let cache = fixture.store.smartEvaluations
        let key = memoKey()
        _ = cache.evaluation(for: first.playlistID, key: key) { [episode("a")] }
        _ = cache.evaluation(for: second.playlistID, key: key) { [episode("b")] }
        #expect(cache.computeCount == 2)

        fixture.store.resetAfterDataNuke()

        let firstAfter = cache.evaluation(for: first.playlistID, key: key) { [] }
        let secondAfter = cache.evaluation(for: second.playlistID, key: key) { [] }
        #expect(firstAfter == .empty)
        #expect(secondAfter == .empty)
        #expect(cache.computeCount == 4)
    }

    @Test("No-op mutations keep an unconsumed error and skip saves and notifications")
    func noOpMutationsStayHonest() throws {
        let fixture = try makeFixture()
        let playlist = try #require(
            fixture.store.create(name: "Commute", kind: .manual, modelContext: fixture.context)
        )
        let firstAdded = fixture.store.add([episode("a")], to: playlist.playlistID, modelContext: fixture.context)
        #expect(firstAdded == 1)
        var changeCount = 0
        fixture.store.onPlaylistsChanged = { changeCount += 1 }
        #expect(!fixture.store.rename(playlist.playlistID, to: " ", modelContext: fixture.context))
        let error = fixture.store.lastErrorMessage
        let saveCount = fixture.probe.saveCount
        let updatedAt = fixture.store.playlists.first?.updatedAt

        let added = fixture.store.add([episode("a")], to: playlist.playlistID, modelContext: fixture.context)
        #expect(added == 0)
        #expect(fixture.store.rename(playlist.playlistID, to: "Commute", modelContext: fixture.context))
        #expect(fixture.store.setHidesPlayed(false, for: playlist.playlistID, modelContext: fixture.context))
        #expect(fixture.store.remove(itemIDs: ["missing"], from: playlist.playlistID, modelContext: fixture.context))
        #expect(
            fixture.store.move(
                fromOffsets: IndexSet(integer: 0),
                toOffset: 1,
                in: playlist.playlistID,
                modelContext: fixture.context
            )
        )
        #expect(fixture.store.delete("missing", modelContext: fixture.context))

        #expect(fixture.store.lastErrorMessage == error)
        #expect(error != nil)
        #expect(changeCount == 0)
        #expect(fixture.probe.saveCount == saveCount)
        #expect(fixture.store.playlists.first?.updatedAt == updatedAt)
    }

    @Test("Successful mutations notify once and failed saves do not notify")
    func successfulMutationsNotifyOnce() throws {
        let fixture = try makeFixture()
        var changeCount = 0
        fixture.store.onPlaylistsChanged = { changeCount += 1 }

        let playlist = try #require(
            fixture.store.create(name: "Commute", kind: .manual, modelContext: fixture.context)
        )
        #expect(changeCount == 1)
        let added = fixture.store.add(
            [episode("a"), episode("b")],
            to: playlist.playlistID,
            modelContext: fixture.context
        )
        #expect(added == 2)
        #expect(changeCount == 2)
        #expect(fixture.store.rename(playlist.playlistID, to: "Evening", modelContext: fixture.context))
        #expect(changeCount == 3)
        #expect(fixture.store.setHidesPlayed(true, for: playlist.playlistID, modelContext: fixture.context))
        #expect(changeCount == 4)
        #expect(fixture.store.setHidesPlayed(false, for: playlist.playlistID, modelContext: fixture.context))
        #expect(changeCount == 5)
        #expect(
            fixture.store.move(
                fromOffsets: IndexSet(integer: 1),
                toOffset: 0,
                in: playlist.playlistID,
                modelContext: fixture.context
            )
        )
        #expect(changeCount == 6)
        let removedItemID = try #require(fixture.store.itemsByPlaylistID[playlist.playlistID]?.first?.itemID)
        #expect(
            fixture.store.remove(
                itemIDs: [removedItemID],
                from: playlist.playlistID,
                modelContext: fixture.context
            )
        )
        #expect(changeCount == 7)

        fixture.probe.failsSaves = true
        #expect(!fixture.store.rename(playlist.playlistID, to: "Night", modelContext: fixture.context))
        let failedAdd = fixture.store.add([episode("c")], to: playlist.playlistID, modelContext: fixture.context)
        #expect(failedAdd == 0)
        #expect(!fixture.store.delete(playlist.playlistID, modelContext: fixture.context))
        #expect(changeCount == 7)

        fixture.probe.failsSaves = false
        #expect(fixture.store.delete(playlist.playlistID, modelContext: fixture.context))
        #expect(changeCount == 8)
    }

    @Test("A move over rows changed behind the store adopts them so the retry succeeds")
    func staleMoveAdoptsStoredRows() throws {
        let fixture = try makeFixture()
        let playlist = try #require(
            fixture.store.create(name: "Commute", kind: .manual, modelContext: fixture.context)
        )
        let added = fixture.store.add(
            ["a", "b", "c"].map { episode($0) },
            to: playlist.playlistID,
            modelContext: fixture.context
        )
        #expect(added == 3)
        let otherContext = ModelContext(fixture.container)
        let otherRecords = try storedItems(in: otherContext)
        let departed = try #require(otherRecords.first(where: { $0.episodeID == "b" }))
        otherContext.delete(departed)
        try otherContext.save()
        var changeCount = 0
        fixture.store.onPlaylistsChanged = { changeCount += 1 }
        let saveCount = fixture.probe.saveCount

        #expect(
            !fixture.store.move(
                fromOffsets: IndexSet(integer: 2),
                toOffset: 0,
                in: playlist.playlistID,
                modelContext: fixture.context
            )
        )

        #expect(fixture.store.lastErrorMessage?.contains("because it changed") == true)
        #expect(fixture.store.itemsByPlaylistID[playlist.playlistID]?.map(\.episodeID) == ["a", "c"])
        #expect(fixture.store.playlists.first?.itemCount == 2)
        #expect(fixture.store.playlists.first?.totalDuration == 120)
        #expect(fixture.store.playlistIDs(containing: "b").isEmpty)
        #expect(fixture.probe.saveCount == saveCount)
        #expect(changeCount == 1)

        #expect(
            fixture.store.move(
                fromOffsets: IndexSet(integer: 1),
                toOffset: 0,
                in: playlist.playlistID,
                modelContext: fixture.context
            )
        )

        let storedContext = ModelContext(fixture.container)
        #expect(fixture.store.itemsByPlaylistID[playlist.playlistID]?.map(\.episodeID) == ["c", "a"])
        #expect(try storedItems(in: storedContext).map(\.episodeID) == ["c", "a"])
        #expect(fixture.store.lastErrorMessage == nil)
    }

    @Test("Sorting oldest or newest first rewrites the keys in one save and bumps updatedAt")
    func sortItemsRewritesKeysInOneSave() throws {
        let fixture = try makeFixture()
        let playlist = try #require(
            fixture.store.create(name: "Commute", kind: .manual, modelContext: fixture.context)
        )
        let added = fixture.store.add(
            [
                episode("march", publishedAt: Self.march),
                episode("january", publishedAt: Self.january),
                episode("february", publishedAt: Self.february)
            ],
            to: playlist.playlistID,
            modelContext: fixture.context
        )
        #expect(added == 3)
        var updatedAt = try #require(fixture.store.playlists.first?.updatedAt)
        let saveCount = fixture.probe.saveCount

        #expect(fixture.store.sortItems(in: playlist.playlistID, by: .oldestFirst, modelContext: fixture.context))

        let oldestFirst = ["january", "february", "march"]
        #expect(fixture.probe.saveCount == saveCount + 1)
        #expect(fixture.store.itemsByPlaylistID[playlist.playlistID]?.map(\.episodeID) == oldestFirst)
        #expect(try storedItems(in: ModelContext(fixture.container)).map(\.episodeID) == oldestFirst)
        #expect(isStrictlyAscending(fixture.store.itemsByPlaylistID[playlist.playlistID]?.map(\.sortKey) ?? []))
        #expect(fixture.store.lastErrorMessage == nil)
        updatedAt = try expectBumpedUpdatedAt(playlist.playlistID, since: updatedAt, fixture: fixture)

        #expect(fixture.store.sortItems(in: playlist.playlistID, by: .newestFirst, modelContext: fixture.context))

        let newestFirst = ["march", "february", "january"]
        #expect(fixture.probe.saveCount == saveCount + 2)
        #expect(fixture.store.itemsByPlaylistID[playlist.playlistID]?.map(\.episodeID) == newestFirst)
        let storedRecords = try storedItems(in: ModelContext(fixture.container))
        #expect(storedRecords.map(\.episodeID) == newestFirst)
        #expect(isStrictlyAscending(storedRecords.map(\.sortKey)))
        #expect(fixture.store.itemsByPlaylistID[playlist.playlistID]?.map(\.sortKey) == storedRecords.map(\.sortKey))
        _ = try expectBumpedUpdatedAt(playlist.playlistID, since: updatedAt, fixture: fixture)

        let reloaded = PlaylistStore()
        reloaded.load(modelContext: ModelContext(fixture.container))
        #expect(reloaded.itemsByPlaylistID[playlist.playlistID]?.map(\.episodeID) == newestFirst)
    }

    @Test("Sorting keeps equal dates in their order and undated episodes last in theirs")
    func sortItemsKeepsTiesAndUndatedOrder() throws {
        let fixture = try makeFixture()
        let playlist = try #require(
            fixture.store.create(name: "Commute", kind: .manual, modelContext: fixture.context)
        )
        let added = fixture.store.add(
            [
                episode("undated-1"),
                episode("february", publishedAt: Self.february),
                episode("january-1", publishedAt: Self.january),
                episode("undated-2"),
                episode("january-2", publishedAt: Self.january)
            ],
            to: playlist.playlistID,
            modelContext: fixture.context
        )
        #expect(added == 5)

        #expect(fixture.store.sortItems(in: playlist.playlistID, by: .oldestFirst, modelContext: fixture.context))
        let oldestFirst = ["january-1", "january-2", "february", "undated-1", "undated-2"]
        #expect(fixture.store.itemsByPlaylistID[playlist.playlistID]?.map(\.episodeID) == oldestFirst)
        #expect(try storedItems(in: ModelContext(fixture.container)).map(\.episodeID) == oldestFirst)

        #expect(fixture.store.sortItems(in: playlist.playlistID, by: .newestFirst, modelContext: fixture.context))
        let newestFirst = ["february", "january-1", "january-2", "undated-1", "undated-2"]
        #expect(fixture.store.itemsByPlaylistID[playlist.playlistID]?.map(\.episodeID) == newestFirst)
        #expect(try storedItems(in: ModelContext(fixture.container)).map(\.episodeID) == newestFirst)
    }

    @Test("Sorting an already sorted or empty playlist succeeds without a save")
    func sortItemsAlreadySortedSavesNothing() throws {
        let fixture = try makeFixture()
        let playlist = try #require(
            fixture.store.create(name: "Commute", kind: .manual, modelContext: fixture.context)
        )
        let empty = try #require(
            fixture.store.create(name: "Empty", kind: .manual, modelContext: fixture.context)
        )
        let added = fixture.store.add(
            [
                episode("january", publishedAt: Self.january),
                episode("february", publishedAt: Self.february),
                episode("undated")
            ],
            to: playlist.playlistID,
            modelContext: fixture.context
        )
        #expect(added == 3)
        let playlistsBefore = fixture.store.playlists
        let itemsBefore = fixture.store.itemsByPlaylistID
        let keysBefore = try storedKeysByItemID(in: fixture.container)
        let saveCount = fixture.probe.saveCount
        var changeCount = 0
        fixture.store.onPlaylistsChanged = { changeCount += 1 }

        #expect(fixture.store.sortItems(in: playlist.playlistID, by: .oldestFirst, modelContext: fixture.context))
        #expect(fixture.store.sortItems(in: empty.playlistID, by: .newestFirst, modelContext: fixture.context))

        #expect(fixture.probe.saveCount == saveCount)
        #expect(changeCount == 0)
        #expect(fixture.store.playlists == playlistsBefore)
        #expect(fixture.store.itemsByPlaylistID == itemsBefore)
        #expect(try storedKeysByItemID(in: fixture.container) == keysBefore)
    }

    @Test("Sorting refuses a smart or missing playlist without saving")
    func sortItemsRefusesSmartAndMissing() throws {
        let fixture = try makeFixture()
        let smart = try #require(
            fixture.store.create(name: "Smart", kind: .smart, modelContext: fixture.context)
        )
        let saveCount = fixture.probe.saveCount

        #expect(!fixture.store.sortItems(in: smart.playlistID, by: .oldestFirst, modelContext: fixture.context))
        #expect(fixture.store.consumeLastErrorMessage() == "Smart playlists choose their own order.")

        #expect(!fixture.store.sortItems(in: "missing", by: .newestFirst, modelContext: fixture.context))
        #expect(fixture.store.consumeLastErrorMessage()?.contains("no longer exists") == true)
        #expect(fixture.probe.saveCount == saveCount)
    }

    @Test("A failed sort leaves memory, keys and storage unchanged")
    func sortItemsRollsBack() throws {
        let fixture = try makeFixture()
        let playlist = try #require(
            fixture.store.create(name: "Commute", kind: .manual, modelContext: fixture.context)
        )
        let added = fixture.store.add(
            [
                episode("february", publishedAt: Self.february),
                episode("january", publishedAt: Self.january)
            ],
            to: playlist.playlistID,
            modelContext: fixture.context
        )
        #expect(added == 2)
        let summaryBefore = fixture.store.playlists
        let itemsBefore = fixture.store.itemsByPlaylistID
        let keysBefore = try storedKeysByItemID(in: fixture.container)
        fixture.probe.failsSaves = true

        #expect(!fixture.store.sortItems(in: playlist.playlistID, by: .oldestFirst, modelContext: fixture.context))

        #expect(fixture.store.playlists == summaryBefore)
        #expect(fixture.store.itemsByPlaylistID == itemsBefore)
        #expect(try storedKeysByItemID(in: fixture.container) == keysBefore)
        #expect(try storedItems(in: fixture.context).map(\.episodeID) == ["february", "january"])
        #expect(fixture.store.lastErrorMessage?.contains("Unable to sort the playlist") == true)
    }

    @Test("Reset after a data nuke clears loaded playlists")
    func resetAfterDataNukeClearsMemory() throws {
        let fixture = try makeFixture()
        let playlist = try #require(
            fixture.store.create(name: "Commute", kind: .manual, modelContext: fixture.context)
        )
        let added = fixture.store.add([episode("a")], to: playlist.playlistID, modelContext: fixture.context)
        #expect(added == 1)
        #expect(!fixture.store.rename(playlist.playlistID, to: "", modelContext: fixture.context))
        var changeCount = 0
        fixture.store.onPlaylistsChanged = { changeCount += 1 }

        fixture.store.resetAfterDataNuke()

        #expect(fixture.store.playlists.isEmpty)
        #expect(fixture.store.itemsByPlaylistID.isEmpty)
        #expect(fixture.store.lastErrorMessage == nil)
        #expect(fixture.store.playlistIDs(containing: "a").isEmpty)
        #expect(changeCount == 1)
    }

    @Test("Consuming the error clears it")
    func consumeLastErrorMessage() throws {
        let fixture = try makeFixture()
        let added = fixture.store.add([episode("a")], to: "missing", modelContext: fixture.context)
        #expect(added == 0)

        let message = fixture.store.consumeLastErrorMessage()

        #expect(message?.contains("no longer exists") == true)
        #expect(fixture.store.lastErrorMessage == nil)
        #expect(fixture.store.consumeLastErrorMessage() == nil)
    }

    private static let january = Date(timeIntervalSince1970: 1_767_355_200)
    private static let february = Date(timeIntervalSince1970: 1_770_033_600)
    private static let march = Date(timeIntervalSince1970: 1_772_452_800)

    private func makeFixture() throws -> (
        store: PlaylistStore,
        probe: PlaylistStoreProbe,
        context: ModelContext,
        container: ModelContainer
    ) {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let probe = PlaylistStoreProbe()
        let store = PlaylistStore(saveModelContext: probe.save, now: probe.nextDate)
        return (store, probe, ModelContext(container), container)
    }

    private func expectBumpedUpdatedAt(
        _ playlistID: String,
        since previous: Date,
        fixture: (
            store: PlaylistStore,
            probe: PlaylistStoreProbe,
            context: ModelContext,
            container: ModelContainer
        )
    ) throws -> Date {
        let summary = try #require(fixture.store.playlists.first(where: { $0.playlistID == playlistID }))
        let storedContext = ModelContext(fixture.container)
        let records = try storedPlaylists(in: storedContext)
        let record = try #require(records.first(where: { $0.playlistID == playlistID }))
        #expect(summary.updatedAt > previous)
        #expect(summary.updatedAt == fixture.probe.latestDate)
        #expect(record.updatedAt == summary.updatedAt)
        return summary.updatedAt
    }

    private func storedPlaylists(in context: ModelContext) throws -> [PlaylistRecord] {
        try context.fetch(FetchDescriptor<PlaylistRecord>(sortBy: [SortDescriptor(\.createdAt)]))
    }

    private func storedItems(in context: ModelContext) throws -> [PlaylistItemRecord] {
        try context.fetch(
            FetchDescriptor<PlaylistItemRecord>(
                sortBy: [
                    SortDescriptor(\.sortKey, comparator: .lexical),
                    SortDescriptor(\.addedAt),
                    SortDescriptor(\.itemID, comparator: .lexical)
                ]
            )
        )
    }

    private func storedKeysByItemID(in container: ModelContainer) throws -> [String: String] {
        let context = ModelContext(container)
        return try Dictionary(
            uniqueKeysWithValues: storedItems(in: context).map { ($0.itemID, $0.sortKey) }
        )
    }

    private func memoKey() -> SmartPlaylistEvaluationKey {
        SmartPlaylistEvaluationKey(
            ruleJSON: PlaylistRule.default.encodedJSON(),
            episodeRevision: 1,
            progressRevision: 1,
            downloadsRevision: nil,
            referenceDate: nil
        )
    }

    private func episode(
        _ episodeID: String,
        podcastID: String = "https://example.com/feed.xml",
        publishedAt: Date? = nil,
        duration: TimeInterval? = 60
    ) -> EpisodeListItemSnapshot {
        .fixture(
            episodeID: episodeID,
            podcastID: podcastID,
            publishedAt: publishedAt,
            duration: duration,
            audioURL: "https://example.com/\(episodeID).mp3",
            guid: episodeID
        )
    }

    private func isStrictlyAscending(_ keys: [String]) -> Bool {
        zip(keys, keys.dropFirst()).allSatisfy { $0 < $1 }
    }
}

/// Stands in for the store's save and clock seams: saves can be made to fail
/// after the store has mutated the context, and every date the store asks for
/// is a minute after the last so `updatedAt` bumps are exact.
private final class PlaylistStoreProbe {
    var failsSaves = false
    private(set) var saveCount = 0
    private(set) var latestDate = Date(timeIntervalSince1970: 1_775_000_000)

    func save(_ context: ModelContext) throws {
        saveCount += 1
        if failsSaves {
            throw PlaylistSaveFailure()
        }
        try context.save()
    }

    func nextDate() -> Date {
        latestDate = latestDate.addingTimeInterval(60)
        return latestDate
    }
}

private struct PlaylistSaveFailure: LocalizedError {
    var errorDescription: String? {
        "Simulated playlist save failure"
    }
}
