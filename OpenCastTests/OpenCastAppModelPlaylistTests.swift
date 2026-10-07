import Foundation
import Intents
import OpenCastCore
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("App model playlists")
struct OpenCastAppModelPlaylistTests {
    private static let podcastID = "https://example.com/playlist-show.xml"
    private static let otherPodcastID = "https://example.com/playlist-other-show.xml"
    private static let commuteID = "playlist-commute"
    private static let emptyID = "playlist-empty"
    private static let commuteItemIDs = ["commute-item-1", "commute-item-2", "commute-item-3"]
    private static let departedFeedURL = "https://old.example.com/playlist-moved-show.xml"
    private static let movedFeedURL = "https://example.com/playlist-moved-show.xml"

    @Test("Core store load publishes stored playlists")
    func coreStoreLoadPublishesPlaylists() async throws {
        let fixture = try await makeFixture()

        #expect(fixture.appModel.playlists.playlists.map(\.playlistID).sorted() == [Self.commuteID, Self.emptyID])
        #expect(fixture.appModel.playlists.itemsByPlaylistID[Self.commuteID]?.map(\.itemID) == Self.commuteItemIDs)
        #expect(fixture.appModel.lastPlaylistError == nil)
    }

    @Test("A data nuke deletes playlist rows and resets the loaded store")
    func nukeResetsPlaylists() async throws {
        let fixture = try await makeFixture()
        #expect(!fixture.appModel.playlists.playlists.isEmpty)
        fixture.appModel.lastPlaylistError = "Previous playlist failure"

        try await fixture.appModel.nukeAllData(modelContext: fixture.context)

        #expect(fixture.appModel.playlists.playlists.isEmpty)
        #expect(fixture.appModel.playlists.itemsByPlaylistID.isEmpty)
        #expect(fixture.appModel.playlists.lastErrorMessage == nil)
        #expect(fixture.appModel.lastPlaylistError == nil)
        #expect(try fixture.context.fetch(FetchDescriptor<PlaylistRecord>()).isEmpty)
        #expect(try fixture.context.fetch(FetchDescriptor<PlaylistItemRecord>()).isEmpty)
    }

    @Test("Unsubscribing leaves playlist rows and the loaded store untouched")
    func unsubscribeLeavesPlaylists() async throws {
        let fixture = try await makeFixture()
        let playlistsBefore = fixture.appModel.playlists.playlists
        let itemsBefore = fixture.appModel.playlists.itemsByPlaylistID
        #expect(fixture.appModel.episodeSnapshot(for: "first") != nil)

        let outcome = await fixture.appModel.unsubscribe(
            feedURL: Self.podcastID,
            modelContext: fixture.context
        )

        #expect(outcome == .removed(warning: nil))
        #expect(fixture.appModel.episodeSnapshot(for: "first") == nil)
        #expect(fixture.appModel.playlists.playlists == playlistsBefore)
        #expect(fixture.appModel.playlists.itemsByPlaylistID == itemsBefore)
        let playlistRecords = try fixture.context.fetch(FetchDescriptor<PlaylistRecord>())
        #expect(playlistRecords.map(\.playlistID).sorted() == [Self.commuteID, Self.emptyID])
        let itemRecords = try fixture.context.fetch(FetchDescriptor<PlaylistItemRecord>())
        #expect(itemRecords.map(\.itemID).sorted() == Self.commuteItemIDs)
        #expect(itemRecords.map(\.episodeID).sorted() == ["elsewhere", "first", "second"])

        // A reload from the rows must not prune the now-unresolvable items.
        fixture.appModel.playlists.load(modelContext: fixture.context)

        #expect(fixture.appModel.playlists.playlists == playlistsBefore)
        #expect(fixture.appModel.playlists.itemsByPlaylistID == itemsBefore)
    }

    @Test("A failed playlist mutation surfaces its error through the app model")
    func failedMutationSurfacesError() async throws {
        let saves = LibrarySaveProbe()
        let fixture = try await makeFixture(librarySave: saves.save)
        saves.failsSaves = true
        let appModel = fixture.appModel
        let context = fixture.context

        appModel.performPlaylistMutation {
            appModel.playlists.rename(Self.commuteID, to: "Renamed", modelContext: context)
        }

        #expect(appModel.lastPlaylistError?.contains("Simulated playlist save failure") == true)
        #expect(appModel.playlists.lastErrorMessage == nil)
        #expect(appModel.playlists.playlists.first { $0.playlistID == Self.commuteID }?.name == "Commute")
        let contextRecords = try context.fetch(FetchDescriptor<PlaylistRecord>())
        #expect(contextRecords.first { $0.playlistID == Self.commuteID }?.name == "Commute")
        let persistedRecords = try ModelContext(fixture.container).fetch(FetchDescriptor<PlaylistRecord>())
        #expect(persistedRecords.first { $0.playlistID == Self.commuteID }?.name == "Commute")
    }

    @Test("The mutation funnel hands back what the store returns")
    func funnelReturnsMutationResult() async throws {
        let fixture = try await makeFixture()
        let appModel = fixture.appModel
        let context = fixture.context

        let created = appModel.performPlaylistMutation {
            appModel.playlists.create(name: "Walks", kind: .manual, modelContext: context)
        }

        #expect(created?.name == "Walks")
        #expect(appModel.lastPlaylistError == nil)

        let unnamed = appModel.performPlaylistMutation {
            appModel.playlists.create(name: " ", kind: .manual, modelContext: context)
        }

        #expect(unnamed == nil)
        #expect(appModel.lastPlaylistError?.contains("enter a name") == true)
        #expect(appModel.playlists.lastErrorMessage == nil)
    }

    @Test("A successful playlist mutation leaves the error surface empty")
    func successfulMutationLeavesErrorEmpty() async throws {
        let fixture = try await makeFixture()
        let appModel = fixture.appModel
        let context = fixture.context

        appModel.performPlaylistMutation {
            appModel.playlists.rename(Self.commuteID, to: "Renamed", modelContext: context)
        }

        #expect(appModel.lastPlaylistError == nil)
        #expect(appModel.playlists.playlists.first { $0.playlistID == Self.commuteID }?.name == "Renamed")
    }

    @Test("A feed-address move carries loaded items onto the successor episode")
    func feedMoveRekeysLoadedItems() async throws {
        let fixture = try await makeFeedMoveFixture()
        let departedEpisodeID = fixture.departedEpisodeID
        let successorEpisodeID = fixture.successorEpisodeID
        #expect(departedEpisodeID != successorEpisodeID)
        let appModel = try makeAppModel(library: fixture.makeLibrary())
        await appModel.ensureCoreStoresLoaded(modelContext: fixture.context)
        #expect(appModel.playlists.playlistIDs(containing: departedEpisodeID) == ["departed-only", "both-episodes"])

        try await appModel.library.migrateSubscription(
            from: Self.departedFeedURL,
            toFeedURL: #require(URL(string: Self.movedFeedURL)),
            modelContext: fixture.context
        )

        #expect(appModel.playlists.playlistIDs(containing: departedEpisodeID).isEmpty)
        #expect(appModel.playlists.playlistIDs(containing: successorEpisodeID) == ["departed-only", "both-episodes"])
        #expect(appModel.playlists.itemsByPlaylistID["both-episodes"]?.map(\.itemID) == ["both-successor-item"])
        let resolved = appModel.playlists.resolvedItems(in: "departed-only") { appModel.episodeSnapshot(for: $0) }
        #expect(resolved.map(\.item.itemID) == ["departed-only-item"])
        #expect(resolved.first?.snapshot?.episodeID == successorEpisodeID)

        // Memory must match what the next launch loads from the migrated rows.
        let reloaded = PlaylistStore(saveSyncedStore: SyncedStoreSelfSaveLedger().save)
        reloaded.load(modelContext: ModelContext(fixture.container))
        #expect(appModel.playlists.itemsByPlaylistID == reloaded.itemsByPlaylistID)
        #expect(appModel.playlists.playlists == reloaded.playlists)
    }

    @Test("A feed-address move whose save fails leaves loaded items on the departed episode")
    func failedFeedMoveKeepsLoadedItems() async throws {
        let fixture = try await makeFeedMoveFixture()
        let departedEpisodeID = fixture.departedEpisodeID
        let successorEpisodeID = fixture.successorEpisodeID
        let saves = LibrarySaveProbe()
        let appModel = try makeAppModel(library: fixture.makeLibrary(save: saves.save))
        await appModel.ensureCoreStoresLoaded(modelContext: fixture.context)
        let playlistsBefore = appModel.playlists.playlists
        let itemsBefore = appModel.playlists.itemsByPlaylistID
        var changeCount = 0
        appModel.playlists.onPlaylistsChanged = { changeCount += 1 }
        saves.failsSaves = true

        await #expect(throws: (any Error).self) {
            try await appModel.library.migrateSubscription(
                from: Self.departedFeedURL,
                toFeedURL: #require(URL(string: Self.movedFeedURL)),
                modelContext: fixture.context
            )
        }

        #expect(changeCount == 0)
        #expect(appModel.playlists.playlists == playlistsBefore)
        #expect(appModel.playlists.itemsByPlaylistID == itemsBefore)
        #expect(appModel.playlists.playlistIDs(containing: departedEpisodeID) == ["departed-only", "both-episodes"])
        #expect(appModel.playlists.playlistIDs(containing: successorEpisodeID) == ["both-episodes"])
        let resolved = appModel.playlists.resolvedItems(in: "departed-only") { appModel.episodeSnapshot(for: $0) }
        #expect(resolved.first?.snapshot?.episodeID == departedEpisodeID)

        // Memory must match what a relaunch loads from the rows the failed
        // save left behind.
        let reloaded = PlaylistStore(saveSyncedStore: SyncedStoreSelfSaveLedger().save)
        reloaded.load(modelContext: ModelContext(fixture.container))
        #expect(appModel.playlists.itemsByPlaylistID == reloaded.itemsByPlaylistID)
        #expect(appModel.playlists.playlists == reloaded.playlists)
    }

    @Test("A feed-address move carries a smart rule's shows onto the new feed URL without an edit")
    func feedMoveRekeysSmartRuleShows() async throws {
        let fixture = try await makeFeedMoveFixture()
        let appModel = try makeAppModel(library: fixture.makeLibrary())
        await appModel.ensureCoreStoresLoaded(modelContext: fixture.context)
        let otherFeedURL = "https://other.example.com/feed.xml"
        let smart = try createSmartPlaylist(
            PlaylistRule(podcastIDs: [Self.departedFeedURL, otherFeedURL], status: .all),
            appModel: appModel,
            context: fixture.context
        )
        #expect(appModel.smartPlaylistEvaluation(for: smart).episodes.map(\.episodeID) == [fixture.departedEpisodeID])

        try await appModel.library.migrateSubscription(
            from: Self.departedFeedURL,
            toFeedURL: #require(URL(string: Self.movedFeedURL)),
            modelContext: fixture.context
        )

        let migrated = try playlistSummary(smart.playlistID, appModel: appModel)
        #expect(migrated.rule?.podcastIDs == [Self.movedFeedURL, otherFeedURL])
        #expect(migrated.updatedAt == smart.updatedAt)
        #expect(appModel.smartPlaylistEvaluation(for: migrated).episodes.map(\.episodeID) == [fixture.successorEpisodeID])
        let reloaded = PlaylistStore(saveSyncedStore: SyncedStoreSelfSaveLedger().save)
        reloaded.load(modelContext: ModelContext(fixture.container))
        #expect(appModel.playlists.playlists == reloaded.playlists)
    }

    @Test("Play starts the first unplayed episode and replaces Up Next with the rest in order")
    func playReplaceStartsFirstUnplayedAndQueuesRest() async throws {
        let fixture = try await makePlayableFixture()
        let appModel = fixture.appModel
        let context = fixture.context
        let queuedUnrelated = appModel.upNextQueue.enqueueLast(unrelatedSnapshot(), modelContext: context)
        #expect(queuedUnrelated)

        let started = appModel.playPlaylist(Self.commuteID, modelContext: context)

        #expect(started)
        #expect(appModel.playback.currentEpisode?.id.rawValue == "first")
        #expect(appModel.upNextQueue.items.map(\.episodeID) == ["third"])
        #expect(appModel.lastPlaylistError == nil)
        #expect(appModel.lastPlaybackError == nil)
        #expect(appModel.lastUpNextError == nil)
        // Playing copies from the playlist; it never consumes it.
        #expect(appModel.playlists.itemsByPlaylistID[Self.commuteID]?.count == 4)
    }

    @Test("Shuffle starts one unplayed episode and queues the other")
    func playShuffleStartsOneUnplayedAndQueuesTheOther() async throws {
        let fixture = try await makePlayableFixture()
        let appModel = fixture.appModel

        let started = appModel.playPlaylist(Self.commuteID, shuffle: true, modelContext: fixture.context)

        #expect(started)
        let current = try #require(appModel.playback.currentEpisode?.id.rawValue)
        let queued = appModel.upNextQueue.items.map(\.episodeID)
        #expect(queued.count == 1)
        #expect(Set([current] + queued) == ["first", "third"])
    }

    @Test("Add after with an idle player queues the playlist and starts its first episode")
    func playAddAfterWithIdlePlayerStartsFirstEpisode() async throws {
        let fixture = try await makePlayableFixture()
        let appModel = fixture.appModel
        #expect(appModel.playback.currentEpisode == nil)
        #expect(appModel.upNextQueue.items.isEmpty)

        let started = appModel.playPlaylist(Self.commuteID, mode: .addAfter, modelContext: fixture.context)

        #expect(started)
        // The advance pops the queue head it starts, so only the rest remains.
        #expect(appModel.playback.currentEpisode?.id.rawValue == "first")
        #expect(appModel.upNextQueue.items.map(\.episodeID) == ["third"])
        #expect(appModel.currentPlaylistSourceID == Self.commuteID)
        #expect(appModel.lastPlaylistError == nil)
    }

    @Test("Add after while a playlist episode plays queues the rest behind Up Next, never the playing one")
    func playAddAfterSkipsPlayingEpisode() async throws {
        let fixture = try await makePlayableFixture()
        let appModel = fixture.appModel
        let context = fixture.context
        let first = try #require(appModel.episodeSnapshot(for: "first"))
        try appModel.playEpisode(first, presentsNowPlaying: false, modelContext: context)
        let queuedUnrelated = appModel.upNextQueue.enqueueLast(unrelatedSnapshot(), modelContext: context)
        #expect(queuedUnrelated)

        let started = appModel.playPlaylist(Self.commuteID, mode: .addAfter, modelContext: context)

        #expect(started)
        #expect(appModel.playback.currentEpisode?.id.rawValue == "first")
        #expect(appModel.upNextQueue.items.map(\.episodeID) == ["unrelated", "third"])
        #expect(appModel.lastPlaylistError == nil)
        #expect(appModel.lastPlaybackError == nil)
        #expect(appModel.lastUpNextError == nil)
    }

    @Test("Play with nothing playable reports it and leaves playback and Up Next alone")
    func playWithNothingPlayableSurfacesError() async throws {
        let fixture = try await makePlayableFixture()
        let appModel = fixture.appModel
        let context = fixture.context
        let queuedUnrelated = appModel.upNextQueue.enqueueLast(unrelatedSnapshot(), modelContext: context)
        #expect(queuedUnrelated)

        let started = appModel.playPlaylist(Self.emptyID, modelContext: context)

        #expect(!started)
        #expect(appModel.lastPlaylistError?.contains("Nothing to play") == true)
        #expect(appModel.playback.currentEpisode == nil)
        #expect(appModel.upNextQueue.items.map(\.episodeID) == ["unrelated"])
    }

    @Test("Play whose first episode fails to start leaves Up Next as it was")
    func playReplaceFailedStartLeavesQueueUntouched() async throws {
        let fixture = try await makeFixture()
        let appModel = fixture.appModel
        let context = fixture.context
        let silent = try #require(appModel.episodeSnapshot(for: "silent"))
        let third = try #require(appModel.episodeSnapshot(for: "third"))
        let addedCount = appModel.performPlaylistMutation {
            appModel.playlists.add([silent, third], to: Self.emptyID, modelContext: context)
        }
        #expect(addedCount == 2)
        let queuedUnrelated = appModel.upNextQueue.enqueueLast(unrelatedSnapshot(), modelContext: context)
        #expect(queuedUnrelated)

        let started = appModel.playPlaylist(Self.emptyID, modelContext: context)

        #expect(!started)
        #expect(appModel.lastPlaybackError != nil)
        #expect(appModel.lastUpNextError == nil)
        #expect(appModel.playback.currentEpisode == nil)
        #expect(appModel.upNextQueue.items.map(\.episodeID) == ["unrelated"])
    }

    @Test("Play whose pour fails leaves Up Next as it was after the clear and reports it")
    func playReplaceFailedPourLeavesQueueAsAfterClear() async throws {
        let saves = UpNextSaveProbe()
        let fixture = try await makePlayableFixture(upNextQueue: UpNextQueueStore(saveModelContext: saves.save))
        let appModel = fixture.appModel
        let context = fixture.context
        try addToCommute(["fourth"], fixture: fixture)
        #expect(appModel.upNextQueue.enqueueLast(unrelatedSnapshot(), modelContext: context))
        saves.failingEpisodeID = "fourth"

        let started = appModel.playPlaylist(Self.commuteID, modelContext: context)

        #expect(!started)
        #expect(appModel.playback.currentEpisode?.id.rawValue == "first")
        // The pour [third, fourth] is one save, so none of it lands.
        #expect(appModel.upNextQueue.items.isEmpty)
        #expect(appModel.lastUpNextError?.contains("Simulated playlist save failure") == true)
        #expect(appModel.currentPlaylistSourceID == Self.commuteID)
        let persisted = try ModelContext(fixture.container).fetch(FetchDescriptor<UpNextQueueItemRecord>())
        #expect(persisted.isEmpty)
    }

    @Test("Play tags every poured row with the playlist and records it as the source")
    func playReplaceTagsQueueAndRemembersSource() async throws {
        let fixture = try await makePlayableFixture()
        let appModel = fixture.appModel
        let context = fixture.context
        try addToCommute(["fourth"], fixture: fixture)
        #expect(appModel.upNextQueue.enqueueLast(unrelatedSnapshot(), modelContext: context))

        let started = appModel.playPlaylist(Self.commuteID, modelContext: context)

        #expect(started)
        #expect(appModel.playback.currentEpisode?.id.rawValue == "first")
        #expect(appModel.upNextQueue.items.map(\.episodeID) == ["third", "fourth"])
        #expect(appModel.upNextQueue.items.map(\.sourcePlaylistID) == [Self.commuteID, Self.commuteID])
        #expect(appModel.currentPlaylistSourceID == Self.commuteID)
        #expect(appModel.currentPlaylistSource == PlaylistPlaybackSource(playlistID: Self.commuteID, name: "Commute"))
        #expect(appModel.remainingQueuedCount(forPlaylist: Self.commuteID) == 2)
        let persisted = try ModelContext(fixture.container).fetch(
            FetchDescriptor<UpNextQueueItemRecord>(sortBy: [SortDescriptor(\.sequence)])
        )
        #expect(persisted.map(\.episodeID) == ["third", "fourth"])
        #expect(persisted.map(\.sourcePlaylistID) == [Self.commuteID, Self.commuteID])
        #expect(try preferenceValues(forKey: PlaybackRestorePreferenceStore.episodeIDKey, in: fixture.container) == ["first"])
        #expect(
            try preferenceValues(forKey: PlaybackRestorePreferenceStore.sourcePlaylistIDKey, in: fixture.container)
                == [Self.commuteID]
        )
    }

    @Test("Add after with an idle player starts the queue head that was already there, untagged")
    func playAddAfterIdleStartsExistingQueueHead() async throws {
        let fixture = try await makePlayableFixture()
        let appModel = fixture.appModel
        let context = fixture.context
        let fourth = try #require(appModel.episodeSnapshot(for: "fourth"))
        #expect(appModel.upNextQueue.enqueueLast(fourth, modelContext: context))

        let started = appModel.playPlaylist(Self.commuteID, mode: .addAfter, modelContext: context)

        #expect(started)
        #expect(appModel.playback.currentEpisode?.id.rawValue == "fourth")
        #expect(appModel.currentPlaylistSourceID == nil)
        #expect(appModel.currentPlaylistSource == nil)
        #expect(appModel.upNextQueue.items.map(\.episodeID) == ["first", "third"])
        #expect(appModel.upNextQueue.items.map(\.sourcePlaylistID) == [Self.commuteID, Self.commuteID])
        #expect(appModel.remainingQueuedCount(forPlaylist: Self.commuteID) == 2)
    }

    @Test("Tapping a row plays from there and puts the rest next, ahead of hand-queued episodes, without clearing")
    func playPlaylistItemPlaysFromHere() async throws {
        let fixture = try await makePlayableFixture()
        let appModel = fixture.appModel
        let context = fixture.context
        try addToCommute(["fourth"], fixture: fixture)
        let third = try #require(appModel.episodeSnapshot(for: "third"))
        #expect(appModel.upNextQueue.enqueueLast(unrelatedSnapshot(), modelContext: context))
        #expect(appModel.upNextQueue.enqueueLast(third, modelContext: context))

        let tappedItemID = try itemID(for: "first", in: Self.commuteID, appModel: appModel)

        let started = appModel.playPlaylistItem(tappedItemID, in: Self.commuteID, modelContext: context)

        #expect(started)
        #expect(appModel.playback.currentEpisode?.id.rawValue == "first")
        // The already-queued third moves into the poured run and takes its tag.
        #expect(appModel.upNextQueue.items.map(\.episodeID) == ["third", "fourth", "unrelated"])
        #expect(appModel.upNextQueue.items.map(\.sourcePlaylistID) == [Self.commuteID, Self.commuteID, nil])
        #expect(appModel.currentPlaylistSourceID == Self.commuteID)
        #expect(appModel.remainingQueuedCount(forPlaylist: Self.commuteID) == 2)
        #expect(appModel.lastPlaylistError == nil)
        #expect(appModel.lastPlaybackError == nil)
        #expect(appModel.lastUpNextError == nil)
        #expect(appModel.playlists.itemsByPlaylistID[Self.commuteID]?.count == 5)
    }

    @Test("A played row is still tappable and queues only the unplayed, resolvable rows after it")
    func playPlaylistItemFromPlayedRow() async throws {
        let fixture = try await makePlayableFixture()
        let appModel = fixture.appModel
        let context = fixture.context
        try addToCommute(["fourth"], fixture: fixture)

        let tappedItemID = try itemID(for: "second", in: Self.commuteID, appModel: appModel)

        let started = appModel.playPlaylistItem(tappedItemID, in: Self.commuteID, modelContext: context)

        #expect(started)
        #expect(appModel.playback.currentEpisode?.id.rawValue == "second")
        #expect(appModel.upNextQueue.items.map(\.episodeID) == ["third", "fourth"])
        #expect(appModel.currentPlaylistSourceID == Self.commuteID)
    }

    @Test("Tapping an unresolvable row reports it and leaves playback and Up Next alone")
    func playPlaylistItemUnresolvableRowSurfacesError() async throws {
        let fixture = try await makePlayableFixture()
        let appModel = fixture.appModel
        let context = fixture.context
        #expect(appModel.upNextQueue.enqueueLast(unrelatedSnapshot(), modelContext: context))

        let tappedItemID = try itemID(for: "elsewhere", in: Self.commuteID, appModel: appModel)

        let started = appModel.playPlaylistItem(tappedItemID, in: Self.commuteID, modelContext: context)

        #expect(!started)
        #expect(appModel.lastPlaylistError == "This episode is no longer available.")
        #expect(appModel.playback.currentEpisode == nil)
        #expect(appModel.currentPlaylistSourceID == nil)
        #expect(appModel.upNextQueue.items.map(\.episodeID) == ["unrelated"])
    }

    @Test("A row whose episode fails to start reports it and leaves Up Next untouched")
    func playPlaylistItemFailedStartLeavesQueueUntouched() async throws {
        let fixture = try await makeFixture()
        let appModel = fixture.appModel
        let context = fixture.context
        let silent = try #require(appModel.episodeSnapshot(for: "silent"))
        let third = try #require(appModel.episodeSnapshot(for: "third"))
        let addedCount = appModel.performPlaylistMutation {
            appModel.playlists.add([silent, third], to: Self.emptyID, modelContext: context)
        }
        #expect(addedCount == 2)
        #expect(appModel.upNextQueue.enqueueLast(unrelatedSnapshot(), modelContext: context))

        let tappedItemID = try itemID(for: "silent", in: Self.emptyID, appModel: appModel)

        let started = appModel.playPlaylistItem(tappedItemID, in: Self.emptyID, modelContext: context)

        #expect(!started)
        #expect(appModel.lastPlaybackError != nil)
        #expect(appModel.lastUpNextError == nil)
        #expect(appModel.playback.currentEpisode == nil)
        #expect(appModel.currentPlaylistSourceID == nil)
        #expect(appModel.upNextQueue.items.map(\.episodeID) == ["unrelated"])
    }

    @Test("Shuffle plays a permutation of the same unplayed episodes, each exactly once, all tagged")
    func shuffleIsPermutationOfCandidates() async throws {
        let fixture = try await makePlayableFixture()
        let appModel = fixture.appModel
        try addToCommute(["fourth"], fixture: fixture)

        let started = appModel.playPlaylist(Self.commuteID, shuffle: true, modelContext: fixture.context)

        #expect(started)
        let current = try #require(appModel.playback.currentEpisode?.id.rawValue)
        let queued = appModel.upNextQueue.items.map(\.episodeID)
        #expect(([current] + queued).count == 3)
        #expect(Set([current] + queued) == ["first", "third", "fourth"])
        #expect(appModel.upNextQueue.items.allSatisfy { $0.sourcePlaylistID == Self.commuteID })
        #expect(appModel.currentPlaylistSourceID == Self.commuteID)
    }

    @Test("Shuffle is ignored for a smart playlist, which plays its evaluation in rule order")
    func shuffleIgnoredForSmartPlaylist() async throws {
        let fixture = try await makePlayableFixture()
        let appModel = fixture.appModel
        let context = fixture.context
        let smart = try createSmartPlaylist(.default, appModel: appModel, context: context)
        #expect((appModel.playlists.itemsByPlaylistID[smart.playlistID] ?? []).isEmpty)

        // Four candidates keep their rule order by chance one shuffle in 24,
        // so repeat the replace: a regression survives all eight only about
        // once in 110 billion runs.
        for _ in 0 ..< 8 {
            let started = appModel.playPlaylist(smart.playlistID, shuffle: true, modelContext: context)

            #expect(started)
            #expect(appModel.playback.currentEpisode?.id.rawValue == "first")
            #expect(appModel.upNextQueue.items.map(\.episodeID) == ["fourth", "silent", "third"])
            #expect(appModel.currentPlaylistSourceID == smart.playlistID)
        }
    }

    @Test("Smart Play replaces Up Next with the evaluation's unplayed episodes in rule order, all tagged")
    func smartPlayReplacesUpNextWithEvaluation() async throws {
        let fixture = try await makePlayableFixture()
        let appModel = fixture.appModel
        let context = fixture.context
        #expect(appModel.upNextQueue.enqueueLast(unrelatedSnapshot(), modelContext: context))
        let smart = try createSmartPlaylist(
            PlaylistRule(status: .unplayed),
            name: "Unplayed",
            appModel: appModel,
            context: context
        )

        let evaluation = appModel.smartPlaylistEvaluation(for: smart)
        let started = appModel.playPlaylist(smart.playlistID, modelContext: context)

        // The feed has no publish dates, so Newest First falls back to titles.
        #expect(evaluation.episodes.map(\.episodeID) == ["first", "fourth", "silent", "third"])
        #expect(evaluation.totalDuration == 240)
        #expect(started)
        #expect(appModel.playback.currentEpisode?.id.rawValue == "first")
        #expect(appModel.upNextQueue.items.map(\.episodeID) == ["fourth", "silent", "third"])
        #expect(appModel.upNextQueue.items.allSatisfy { $0.sourcePlaylistID == smart.playlistID })
        #expect(appModel.currentPlaylistSourceID == smart.playlistID)
        #expect(
            appModel.currentPlaylistSource == PlaylistPlaybackSource(playlistID: smart.playlistID, name: "Unplayed")
        )
        #expect(appModel.remainingQueuedCount(forPlaylist: smart.playlistID) == 3)
        #expect(appModel.lastPlaylistError == nil)
        #expect(appModel.lastPlaybackError == nil)
        #expect(appModel.lastUpNextError == nil)
    }

    @Test("Smart Play takes the rule's limited list, then skips its played episodes")
    func smartPlayAppliesLimitBeforeSkippingPlayed() async throws {
        let fixture = try await makePlayableFixture()
        let appModel = fixture.appModel
        let context = fixture.context
        let smart = try createSmartPlaylist(
            PlaylistRule(status: .all, limit: 3),
            appModel: appModel,
            context: context
        )

        let evaluation = appModel.smartPlaylistEvaluation(for: smart)
        let started = appModel.playPlaylist(smart.playlistID, modelContext: context)

        #expect(evaluation.episodes.map(\.episodeID) == ["first", "fourth", "second"])
        #expect(started)
        #expect(appModel.playback.currentEpisode?.id.rawValue == "first")
        #expect(appModel.upNextQueue.items.map(\.episodeID) == ["fourth"])
        #expect(appModel.upNextQueue.items.map(\.sourcePlaylistID) == [smart.playlistID])
    }

    @Test("A Played rule lists its played episodes but has nothing to play, queue or download")
    func smartPlayedRuleHasNothingToPlay() async throws {
        let fixture = try await makePlayableFixture()
        let appModel = fixture.appModel
        let context = fixture.context
        #expect(appModel.upNextQueue.enqueueLast(unrelatedSnapshot(), modelContext: context))
        let smart = try createSmartPlaylist(PlaylistRule(status: .played), appModel: appModel, context: context)

        #expect(appModel.smartPlaylistEvaluation(for: smart).episodes.map(\.episodeID) == ["second"])

        let started = appModel.playPlaylist(smart.playlistID, modelContext: context)

        #expect(!started)
        #expect(appModel.lastPlaylistError?.contains("Nothing to play") == true)
        #expect(appModel.playback.currentEpisode == nil)
        #expect(appModel.upNextQueue.items.map(\.episodeID) == ["unrelated"])

        appModel.lastPlaylistError = nil
        let queued = appModel.enqueuePlaylist(smart.playlistID, position: .next, modelContext: context)

        #expect(!queued)
        #expect(appModel.lastPlaylistError?.contains("Nothing to play") == true)
        #expect(appModel.upNextQueue.items.map(\.episodeID) == ["unrelated"])
        #expect(appModel.playlistDownloadAllCandidates(smart.playlistID).isEmpty)
        #expect(!appModel.hasPlaylistDownloadAllCandidates(smart.playlistID))
    }

    @Test("Smart playback treats an episode finished by position as played even when its row is not flagged")
    func smartCandidatesFollowCompletionNotThePlayedFlag() async throws {
        let fixture = try await makePlayableFixture()
        let appModel = fixture.appModel
        let context = fixture.context
        // With no stored duration the writer leaves the flag false, while the
        // summary measures position 59 against the episode's own 60 s. A
        // manual playlist would still play this episode.
        let wroteProgress = appModel.library.updateProgress(
            episodeID: "fourth",
            podcastID: Self.podcastID,
            position: 59,
            duration: nil,
            modelContext: context
        )
        #expect(wroteProgress)
        let fourth = try #require(appModel.episodeSnapshot(for: "fourth"))
        #expect(appModel.library.progressRecord(for: "fourth")?.isPlayed == false)
        #expect(appModel.library.progressSummary(for: fourth).isCompleted)
        #expect(appModel.upNextQueue.enqueueLast(unrelatedSnapshot(), modelContext: context))
        let played = try createSmartPlaylist(
            PlaylistRule(status: .played),
            name: "Played",
            appModel: appModel,
            context: context
        )
        let everything = try createSmartPlaylist(
            PlaylistRule(status: .all),
            name: "Everything",
            appModel: appModel,
            context: context
        )
        let playedEpisodes = appModel.smartPlaylistEvaluation(for: played).episodes
        let everyEpisode = appModel.smartPlaylistEvaluation(for: everything).episodes

        #expect(playedEpisodes.map(\.episodeID) == ["fourth", "second"])
        #expect(PlaylistPrimaryAction.resolve(smartEpisodes: playedEpisodes, library: appModel.library) == nil)
        #expect(PlaylistPrimaryAction.resolve(smartEpisodes: everyEpisode, library: appModel.library) == .play)
        #expect(appModel.playlistDownloadAllCandidates(played.playlistID).isEmpty)
        #expect(!appModel.hasPlaylistDownloadAllCandidates(played.playlistID))

        let started = appModel.playPlaylist(played.playlistID, modelContext: context)

        #expect(!started)
        #expect(appModel.lastPlaylistError?.contains("Nothing to play") == true)
        #expect(appModel.playback.currentEpisode == nil)
        #expect(appModel.upNextQueue.items.map(\.episodeID) == ["unrelated"])

        appModel.lastPlaylistError = nil
        let playedFromHere = appModel.playPlaylistEpisode("first", in: everything.playlistID, modelContext: context)

        #expect(playedFromHere)
        #expect(appModel.playback.currentEpisode?.id.rawValue == "first")
        #expect(appModel.upNextQueue.items.map(\.episodeID) == ["silent", "third", "unrelated"])
        #expect(appModel.lastPlaylistError == nil)
    }

    @Test("Tapping a smart row plays from there and puts the unplayed rest of the evaluation next, tagged")
    func playPlaylistEpisodePlaysFromHereForSmart() async throws {
        let fixture = try await makePlayableFixture()
        let appModel = fixture.appModel
        let context = fixture.context
        #expect(appModel.upNextQueue.enqueueLast(unrelatedSnapshot(), modelContext: context))
        let smart = try createSmartPlaylist(
            PlaylistRule(status: .all),
            name: "Everything",
            appModel: appModel,
            context: context
        )
        #expect(
            appModel.smartPlaylistEvaluation(for: smart).episodes.map(\.episodeID)
                == ["first", "fourth", "second", "silent", "third"]
        )

        let started = appModel.playPlaylistEpisode("fourth", in: smart.playlistID, modelContext: context)

        #expect(started)
        #expect(appModel.playback.currentEpisode?.id.rawValue == "fourth")
        // The played second stays out of the queue.
        #expect(appModel.upNextQueue.items.map(\.episodeID) == ["silent", "third", "unrelated"])
        #expect(appModel.upNextQueue.items.map(\.sourcePlaylistID) == [smart.playlistID, smart.playlistID, nil])
        #expect(appModel.currentPlaylistSourceID == smart.playlistID)
        #expect(appModel.remainingQueuedCount(forPlaylist: smart.playlistID) == 2)
        #expect(appModel.lastPlaylistError == nil)
        #expect(appModel.lastPlaybackError == nil)
        #expect(appModel.lastUpNextError == nil)
    }

    @Test("A played smart row is still tappable, and a row the rules no longer list reports it")
    func playPlaylistEpisodeSmartPlayedAndUnlistedRows() async throws {
        let fixture = try await makePlayableFixture()
        let appModel = fixture.appModel
        let context = fixture.context
        #expect(appModel.upNextQueue.enqueueLast(unrelatedSnapshot(), modelContext: context))
        let unplayed = try createSmartPlaylist(.default, name: "Unplayed", appModel: appModel, context: context)
        let everything = try createSmartPlaylist(
            PlaylistRule(status: .all),
            name: "Everything",
            appModel: appModel,
            context: context
        )

        let unlisted = appModel.playPlaylistEpisode("second", in: unplayed.playlistID, modelContext: context)

        #expect(!unlisted)
        #expect(appModel.lastPlaylistError == "This episode is no longer available.")
        #expect(appModel.playback.currentEpisode == nil)
        #expect(appModel.currentPlaylistSourceID == nil)
        #expect(appModel.upNextQueue.items.map(\.episodeID) == ["unrelated"])

        appModel.lastPlaylistError = nil
        let started = appModel.playPlaylistEpisode("second", in: everything.playlistID, modelContext: context)

        #expect(started)
        #expect(appModel.playback.currentEpisode?.id.rawValue == "second")
        #expect(appModel.upNextQueue.items.map(\.episodeID) == ["silent", "third", "unrelated"])
        #expect(appModel.currentPlaylistSourceID == everything.playlistID)
        #expect(appModel.lastPlaylistError == nil)
    }

    @Test("Tapping a manual row by episode plays from there, and a missing or unresolvable episode reports it")
    func playPlaylistEpisodePlaysFromHereForManual() async throws {
        let fixture = try await makePlayableFixture()
        let appModel = fixture.appModel
        let context = fixture.context
        try addToCommute(["fourth"], fixture: fixture)
        #expect(appModel.upNextQueue.enqueueLast(unrelatedSnapshot(), modelContext: context))

        let missing = appModel.playPlaylistEpisode("silent", in: Self.commuteID, modelContext: context)

        #expect(!missing)
        #expect(appModel.lastPlaylistError == "This episode is no longer available.")

        appModel.lastPlaylistError = nil
        let unresolvable = appModel.playPlaylistEpisode("elsewhere", in: Self.commuteID, modelContext: context)

        #expect(!unresolvable)
        #expect(appModel.lastPlaylistError == "This episode is no longer available.")
        #expect(appModel.playback.currentEpisode == nil)
        #expect(appModel.upNextQueue.items.map(\.episodeID) == ["unrelated"])

        appModel.lastPlaylistError = nil
        let started = appModel.playPlaylistEpisode("second", in: Self.commuteID, modelContext: context)

        #expect(started)
        #expect(appModel.playback.currentEpisode?.id.rawValue == "second")
        #expect(appModel.upNextQueue.items.map(\.episodeID) == ["third", "fourth", "unrelated"])
        #expect(appModel.upNextQueue.items.map(\.sourcePlaylistID) == [Self.commuteID, Self.commuteID, nil])
        #expect(appModel.currentPlaylistSourceID == Self.commuteID)
        #expect(appModel.lastPlaylistError == nil)
        #expect(appModel.lastPlaybackError == nil)
        #expect(appModel.lastUpNextError == nil)
    }

    @Test("A smart evaluation recomputes after Mark Played edits an existing progress row, and not on unrelated reads")
    func smartEvaluationTracksInPlaceProgressEdits() async throws {
        let fixture = try await makePlayableFixture()
        let appModel = fixture.appModel
        let context = fixture.context
        let first = try #require(appModel.episodeSnapshot(for: "first"))
        let wroteProgress = appModel.library.updateProgress(
            episodeID: "first",
            podcastID: Self.podcastID,
            position: 10,
            duration: 60,
            modelContext: context
        )
        #expect(wroteProgress)
        let existingRow = try #require(appModel.library.progressRecord(for: "first"))
        #expect(!existingRow.isPlayed)
        let smart = try createSmartPlaylist(.default, appModel: appModel, context: context)
        let cache = appModel.playlists.smartEvaluations

        let before = appModel.smartPlaylistEvaluation(for: smart)
        let computeCount = cache.computeCount
        let reread = appModel.smartPlaylistEvaluation(for: smart)
        #expect(appModel.upNextQueue.enqueueLast(unrelatedSnapshot(), modelContext: context))
        _ = appModel.library.progressSummary(for: first)
        let afterUnrelated = appModel.smartPlaylistEvaluation(for: smart)

        #expect(before.episodes.map(\.episodeID) == ["first", "fourth", "silent", "third"])
        #expect(reread == before)
        #expect(afterUnrelated == before)
        #expect(cache.computeCount == computeCount)

        #expect(appModel.markEpisodePlayed(first, modelContext: context))
        let after = appModel.smartPlaylistEvaluation(for: smart)

        // The edit landed on the row that already existed, which no index
        // membership change reports.
        #expect(appModel.library.progressRecord(for: "first") === existingRow)
        #expect(existingRow.isPlayed)
        #expect(after.episodes.map(\.episodeID) == ["fourth", "silent", "third"])
        #expect(cache.computeCount == computeCount + 1)
    }

    @Test("A position-only progress flush keeps a played-state evaluation, and finishing the episode recomputes it")
    func positionOnlyFlushKeepsSmartEvaluation() async throws {
        let fixture = try await makePlayableFixture()
        let appModel = fixture.appModel
        let context = fixture.context
        #expect(
            appModel.library.updateProgress(
                episodeID: "first",
                podcastID: Self.podcastID,
                position: 10,
                duration: 60,
                modelContext: context
            )
        )
        let smart = try createSmartPlaylist(.default, appModel: appModel, context: context)
        let cache = appModel.playlists.smartEvaluations
        let before = appModel.smartPlaylistEvaluation(for: smart)
        let computeCount = cache.computeCount

        #expect(
            appModel.library.updateProgress(
                episodeID: "first",
                podcastID: Self.podcastID,
                position: 20,
                duration: 60,
                modelContext: context
            )
        )
        #expect(appModel.smartPlaylistEvaluation(for: smart) == before)
        #expect(cache.computeCount == computeCount)

        #expect(
            appModel.library.updateProgress(
                episodeID: "first",
                podcastID: Self.podcastID,
                position: 59,
                duration: 60,
                modelContext: context
            )
        )
        let after = appModel.smartPlaylistEvaluation(for: smart)
        #expect(!after.episodes.contains { $0.episodeID == "first" })
        #expect(cache.computeCount == computeCount + 1)
    }

    @Test("An All Episodes evaluation ignores played-state changes and recomputes when its rule changes")
    func allEpisodesEvaluationIgnoresProgressButFollowsRule() async throws {
        let fixture = try await makePlayableFixture()
        let appModel = fixture.appModel
        let context = fixture.context
        let smart = try createSmartPlaylist(PlaylistRule(status: .all), appModel: appModel, context: context)
        let cache = appModel.playlists.smartEvaluations
        let before = appModel.smartPlaylistEvaluation(for: smart)
        let computeCount = cache.computeCount
        let fourth = try #require(appModel.episodeSnapshot(for: "fourth"))

        #expect(appModel.markEpisodePlayed(fourth, modelContext: context))
        let afterMarkPlayed = appModel.smartPlaylistEvaluation(for: smart)

        #expect(afterMarkPlayed == before)
        #expect(cache.computeCount == computeCount)

        let didSetRule = appModel.performPlaylistMutation {
            appModel.playlists.setRule(PlaylistRule(status: .played), for: smart.playlistID, modelContext: context)
        }
        let updated = try playlistSummary(smart.playlistID, appModel: appModel)
        let played = appModel.smartPlaylistEvaluation(for: updated)

        #expect(didSetRule)
        #expect(appModel.lastPlaylistError == nil)
        #expect(played.episodes.map(\.episodeID) == ["fourth", "second"])
        #expect(cache.computeCount == computeCount + 1)
    }

    @Test("Download All for a smart playlist offers its unplayed episodes without a completed download")
    func smartDownloadAllCandidates() async throws {
        let directory = try makeTemporaryDirectory()
        let fileStore = EpisodeDownloadFileStore(baseDirectory: directory)
        let fixture = try await makePlayableFixture(
            downloads: DownloadStore(downloader: RecordingHangingEpisodeAudioDownloader(), fileStore: fileStore)
        )
        let appModel = fixture.appModel
        let context = fixture.context
        try insertCompletedDownload(episodeID: "first", writesFile: true, fileStore: fileStore, context: context)
        try context.save()
        await appModel.downloads.load(modelContext: context)
        let smart = try createSmartPlaylist(.default, appModel: appModel, context: context)
        let downloaded = try createSmartPlaylist(
            PlaylistRule(status: .unplayed, downloadedOnly: true),
            name: "Downloaded",
            appModel: appModel,
            context: context
        )

        #expect(appModel.playlistDownloadAllCandidates(smart.playlistID).map(\.episodeID) == ["fourth", "silent", "third"])
        #expect(appModel.hasPlaylistDownloadAllCandidates(smart.playlistID))
        #expect(appModel.smartPlaylistEvaluation(for: downloaded).episodes.map(\.episodeID) == ["first"])
        #expect(appModel.playlistDownloadAllCandidates(downloaded.playlistID).isEmpty)
        #expect(!appModel.hasPlaylistDownloadAllCandidates(downloaded.playlistID))
    }

    @Test("A Downloaded Only evaluation recomputes when a download completes")
    func downloadedOnlyEvaluationFollowsDownloadRecords() async throws {
        let directory = try makeTemporaryDirectory()
        let fileStore = EpisodeDownloadFileStore(baseDirectory: directory)
        let fixture = try await makePlayableFixture(
            downloads: DownloadStore(downloader: RecordingHangingEpisodeAudioDownloader(), fileStore: fileStore)
        )
        let appModel = fixture.appModel
        let context = fixture.context
        let downloaded = try createSmartPlaylist(
            PlaylistRule(status: .all, downloadedOnly: true),
            name: "Downloaded",
            appModel: appModel,
            context: context
        )
        let cache = appModel.playlists.smartEvaluations

        #expect(appModel.smartPlaylistEvaluation(for: downloaded).episodes.isEmpty)
        let computeCount = cache.computeCount

        try insertCompletedDownload(episodeID: "fourth", writesFile: true, fileStore: fileStore, context: context)
        try context.save()
        await appModel.downloads.load(modelContext: context)
        let after = appModel.smartPlaylistEvaluation(for: downloaded)

        #expect(after.episodes.map(\.episodeID) == ["fourth"])
        #expect(cache.computeCount == computeCount + 1)
    }

    @Test("An age rule recomputes when the library's reference date moves, and a rule without one does not")
    func ageEvaluationFollowsReferenceDate() async throws {
        var currentDate = Date(timeIntervalSince1970: 1_800_000_000)
        let fixture = try await makePlayableFixture(libraryNow: { currentDate })
        let appModel = fixture.appModel
        let context = fixture.context
        let recent = try createSmartPlaylist(
            PlaylistRule(status: .all, maximumAgeDays: 7),
            name: "Recent",
            appModel: appModel,
            context: context
        )
        let everything = try createSmartPlaylist(
            PlaylistRule(status: .all),
            name: "Everything",
            appModel: appModel,
            context: context
        )
        let cache = appModel.playlists.smartEvaluations
        _ = appModel.smartPlaylistEvaluation(for: recent)
        _ = appModel.smartPlaylistEvaluation(for: everything)
        let computeCount = cache.computeCount

        currentDate += 120
        appModel.library.advanceNewEpisodeReferenceDate()
        _ = appModel.smartPlaylistEvaluation(for: recent)
        _ = appModel.smartPlaylistEvaluation(for: everything)

        #expect(appModel.library.newEpisodeReferenceDate == currentDate)
        #expect(cache.computeCount == computeCount + 1)
    }

    @Test("A smart row stored without rule JSON plays as the default rule, and an unreadable rule evaluates to nothing")
    func storedSmartRowsEvaluateByTheirRules() async throws {
        let fixture = try await makePlayableFixture()
        let appModel = fixture.appModel
        let context = fixture.context
        let createdAt = Date(timeIntervalSince1970: 1_775_000_000)
        context.insert(
            PlaylistRecord(
                playlistID: "smart-unset",
                name: "Unset",
                kind: .smart,
                createdAt: createdAt,
                updatedAt: createdAt
            )
        )
        context.insert(
            PlaylistRecord(
                playlistID: "smart-newer",
                name: "Newer",
                kind: .smart,
                ruleJSON: #"{"version":2}"#,
                createdAt: createdAt,
                updatedAt: createdAt
            )
        )
        try context.save()
        appModel.playlists.load(modelContext: context)
        let unset = try playlistSummary("smart-unset", appModel: appModel)
        let newer = try playlistSummary("smart-newer", appModel: appModel)
        let commute = try playlistSummary(Self.commuteID, appModel: appModel)

        #expect(unset.rule == .default)
        #expect(
            appModel.smartPlaylistEvaluation(for: unset).episodes.map(\.episodeID)
                == ["first", "fourth", "silent", "third"]
        )
        #expect(newer.hasUnreadableRule)
        #expect(appModel.smartPlaylistEvaluation(for: newer) == .empty)
        #expect(appModel.smartPlaylistEvaluation(for: commute) == .empty)

        let started = appModel.playPlaylist("smart-newer", modelContext: context)

        #expect(!started)
        #expect(appModel.lastPlaylistError?.contains("Nothing to play") == true)
        #expect(appModel.playback.currentEpisode == nil)
    }

    @Test("Play Next puts the playlist ahead of Up Next in order without starting playback")
    func enqueuePlaylistNextDoesNotStart() async throws {
        let fixture = try await makePlayableFixture()
        let appModel = fixture.appModel
        let context = fixture.context
        #expect(appModel.upNextQueue.enqueueLast(unrelatedSnapshot(), modelContext: context))

        let queued = appModel.enqueuePlaylist(Self.commuteID, position: .next, modelContext: context)

        #expect(queued)
        #expect(appModel.playback.currentEpisode == nil)
        #expect(appModel.currentPlaylistSourceID == nil)
        #expect(appModel.upNextQueue.items.map(\.episodeID) == ["first", "third", "unrelated"])
        #expect(appModel.upNextQueue.items.map(\.sourcePlaylistID) == [Self.commuteID, Self.commuteID, nil])
        #expect(appModel.remainingQueuedCount(forPlaylist: Self.commuteID) == 2)
        #expect(appModel.lastPlaylistError == nil)
        #expect(appModel.lastUpNextError == nil)
    }

    @Test("Play Last appends the playlist, skips the playing episode, and never changes what plays")
    func enqueuePlaylistLastSkipsPlayingEpisode() async throws {
        let fixture = try await makePlayableFixture()
        let appModel = fixture.appModel
        let context = fixture.context
        let first = try #require(appModel.episodeSnapshot(for: "first"))
        try appModel.playEpisode(first, presentsNowPlaying: false, modelContext: context)
        #expect(appModel.upNextQueue.enqueueLast(unrelatedSnapshot(), modelContext: context))

        let queued = appModel.enqueuePlaylist(Self.commuteID, position: .last, modelContext: context)

        #expect(queued)
        #expect(appModel.playback.currentEpisode?.id.rawValue == "first")
        #expect(appModel.currentPlaylistSourceID == nil)
        #expect(appModel.upNextQueue.items.map(\.episodeID) == ["unrelated", "third"])
        #expect(appModel.upNextQueue.items.map(\.sourcePlaylistID) == [nil, Self.commuteID])
    }

    @Test("Play Next with nothing to queue reports it and leaves Up Next alone")
    func enqueuePlaylistWithNothingPlayableSurfacesError() async throws {
        let fixture = try await makePlayableFixture()
        let appModel = fixture.appModel
        let context = fixture.context
        #expect(appModel.upNextQueue.enqueueLast(unrelatedSnapshot(), modelContext: context))

        let queued = appModel.enqueuePlaylist(Self.emptyID, position: .next, modelContext: context)

        #expect(!queued)
        #expect(appModel.lastPlaylistError?.contains("Nothing to play") == true)
        #expect(appModel.upNextQueue.items.map(\.episodeID) == ["unrelated"])
        #expect(appModel.playback.currentEpisode == nil)
    }

    @Test("Play Next / Play Last when the only candidate is playing is a quiet no-op, not an error")
    func enqueuePlaylistWithOnlyPlayingCandidateIsNoOp() async throws {
        let fixture = try await makePlayableFixture()
        let appModel = fixture.appModel
        let context = fixture.context
        let third = try #require(appModel.episodeSnapshot(for: "third"))
        #expect(appModel.markEpisodePlayed(third, modelContext: context))
        let first = try #require(appModel.episodeSnapshot(for: "first"))
        try appModel.playEpisode(first, presentsNowPlaying: false, modelContext: context)
        #expect(appModel.upNextQueue.enqueueLast(unrelatedSnapshot(), modelContext: context))

        for position in [UpNextQueuePosition.next, .last] {
            #expect(appModel.enqueuePlaylist(Self.commuteID, position: position, modelContext: context))
        }

        #expect(appModel.lastPlaylistError == nil)
        #expect(appModel.lastUpNextError == nil)
        #expect(appModel.playback.currentEpisode?.id.rawValue == "first")
        #expect(appModel.upNextQueue.items.map(\.episodeID) == ["unrelated"])
    }

    @Test("Advancing to a tagged queue item makes its playlist the source; an untagged start clears it")
    func advanceDerivesSourceAndUntaggedPlayClearsIt() async throws {
        let fixture = try await makePlayableFixture()
        let appModel = fixture.appModel
        let context = fixture.context
        let fourth = try #require(appModel.episodeSnapshot(for: "fourth"))
        try appModel.playEpisode(fourth, presentsNowPlaying: false, modelContext: context)
        #expect(appModel.currentPlaylistSourceID == nil)
        #expect(appModel.enqueuePlaylist(Self.commuteID, position: .last, modelContext: context))
        #expect(appModel.currentPlaylistSourceID == nil)

        #expect(appModel.advanceToNextQueuedEpisode(modelContext: context))

        #expect(appModel.playback.currentEpisode?.id.rawValue == "first")
        #expect(appModel.currentPlaylistSourceID == Self.commuteID)
        #expect(appModel.remainingQueuedCount(forPlaylist: Self.commuteID) == 1)
        #expect(
            try preferenceValues(forKey: PlaybackRestorePreferenceStore.sourcePlaylistIDKey, in: fixture.container)
                == [Self.commuteID]
        )

        try appModel.playEpisode(fourth, presentsNowPlaying: false, modelContext: context)

        #expect(appModel.playback.currentEpisode?.id.rawValue == "fourth")
        #expect(appModel.currentPlaylistSourceID == nil)
        #expect(appModel.currentPlaylistSource == nil)
        #expect(try preferenceValues(forKey: PlaybackRestorePreferenceStore.episodeIDKey, in: fixture.container) == ["fourth"])
        #expect(try preferenceValues(forKey: PlaybackRestorePreferenceStore.sourcePlaylistIDKey, in: fixture.container).isEmpty)
        #expect(appModel.upNextQueue.items.map(\.sourcePlaylistID) == [Self.commuteID])
    }

    @Test("Playing a tagged row straight from Up Next derives the source from its tag")
    func directPlayOfTaggedQueueRowDerivesSource() async throws {
        let fixture = try await makePlayableFixture()
        let appModel = fixture.appModel
        let context = fixture.context
        #expect(appModel.enqueuePlaylist(Self.commuteID, position: .last, modelContext: context))
        let third = try #require(appModel.episodeSnapshot(for: "third"))

        try appModel.playEpisode(third, presentsNowPlaying: false, modelContext: context)

        #expect(appModel.playback.currentEpisode?.id.rawValue == "third")
        #expect(appModel.currentPlaylistSourceID == Self.commuteID)
        #expect(appModel.upNextQueue.items.map(\.episodeID) == ["first"])
        #expect(appModel.remainingQueuedCount(forPlaylist: Self.commuteID) == 1)
    }

    @Test("The source persists with the restore key, and a relaunch restores it with the queue's tags")
    func sourceSurvivesRelaunchThroughRestore() async throws {
        let fixture = try await makePlayableFixture()
        let appModel = fixture.appModel
        #expect(appModel.playPlaylist(Self.commuteID, modelContext: fixture.context))
        #expect(appModel.currentPlaylistSourceID == Self.commuteID)
        // Unloading directly keeps both restore rows, as a process exit would.
        appModel.playback.unload()

        let relaunched = try makeAppModel(library: LibraryStore(localCache: fixture.cache))
        let relaunchContext = ModelContext(fixture.container)
        await relaunched.ensureCoreStoresLoaded(modelContext: relaunchContext)
        #expect(relaunched.currentPlaylistSourceID == nil)
        #expect(relaunched.upNextQueue.items.map(\.sourcePlaylistID) == [Self.commuteID])

        relaunched.restorePreviousPlaybackIfAvailable(modelContext: relaunchContext)

        #expect(relaunched.playback.currentEpisode?.id.rawValue == "first")
        #expect(relaunched.currentPlaylistSourceID == Self.commuteID)
        #expect(relaunched.currentPlaylistSource == PlaylistPlaybackSource(playlistID: Self.commuteID, name: "Commute"))
        #expect(relaunched.remainingQueuedCount(forPlaylist: Self.commuteID) == 1)

        relaunched.playback.unload()
    }

    @Test("Stopping playback clears the source and both restore rows but keeps the queue's tags")
    func stopClearsSource() async throws {
        let fixture = try await makePlayableFixture()
        let appModel = fixture.appModel
        let context = fixture.context
        #expect(appModel.playPlaylist(Self.commuteID, modelContext: context))
        #expect(appModel.currentPlaylistSourceID == Self.commuteID)

        #expect(appModel.dismissCurrentPlayback(modelContext: context))
        await appModel.deferredPlaybackTeardownTask?.value

        #expect(appModel.playback.currentEpisode == nil)
        #expect(appModel.currentPlaylistSourceID == nil)
        #expect(appModel.currentPlaylistSource == nil)
        #expect(try preferenceValues(forKey: PlaybackRestorePreferenceStore.episodeIDKey, in: fixture.container).isEmpty)
        #expect(try preferenceValues(forKey: PlaybackRestorePreferenceStore.sourcePlaylistIDKey, in: fixture.container).isEmpty)
        #expect(appModel.upNextQueue.items.map(\.sourcePlaylistID) == [Self.commuteID])
    }

    @Test("The remaining count covers only the playlist's own queued rows")
    func remainingCountCountsOnlyTaggedRows() async throws {
        let fixture = try await makePlayableFixture()
        let appModel = fixture.appModel
        let context = fixture.context
        try addToCommute(["fourth"], fixture: fixture)
        #expect(appModel.playPlaylist(Self.commuteID, modelContext: context))
        #expect(appModel.upNextQueue.enqueueLast(unrelatedSnapshot(), modelContext: context))

        #expect(appModel.remainingQueuedCount(forPlaylist: Self.commuteID) == 2)
        #expect(appModel.remainingQueuedCount(forPlaylist: Self.emptyID) == 0)

        #expect(appModel.advanceToNextQueuedEpisode(modelContext: context))

        #expect(appModel.playback.currentEpisode?.id.rawValue == "third")
        #expect(appModel.remainingQueuedCount(forPlaylist: Self.commuteID) == 1)
        #expect(appModel.upNextQueue.items.count == 2)
    }

    @Test("Renaming the source playlist renames the label; deleting it hides the source and keeps the queue and its tags")
    func renameAndDeleteOfSourcePlaylist() async throws {
        let fixture = try await makePlayableFixture()
        let appModel = fixture.appModel
        let context = fixture.context
        #expect(appModel.playPlaylist(Self.commuteID, modelContext: context))

        appModel.performPlaylistMutation {
            appModel.playlists.rename(Self.commuteID, to: "Morning", modelContext: context)
        }

        #expect(appModel.currentPlaylistSource?.name == "Morning")

        appModel.performPlaylistMutation {
            appModel.playlists.delete(Self.commuteID, modelContext: context)
        }

        #expect(appModel.lastPlaylistError == nil)
        #expect(appModel.currentPlaylistSource == nil)
        #expect(appModel.playback.currentEpisode?.id.rawValue == "first")
        #expect(appModel.upNextQueue.items.map(\.episodeID) == ["third"])
        #expect(appModel.upNextQueue.items.map(\.sourcePlaylistID) == [Self.commuteID])
        let persisted = try ModelContext(fixture.container).fetch(FetchDescriptor<UpNextQueueItemRecord>())
        #expect(persisted.map(\.sourcePlaylistID) == [Self.commuteID])
    }

    @Test("A data nuke clears the playlist source with the queue and the restore rows")
    func nukeClearsPlaylistSource() async throws {
        let fixture = try await makePlayableFixture()
        let appModel = fixture.appModel
        #expect(appModel.playPlaylist(Self.commuteID, modelContext: fixture.context))
        #expect(appModel.currentPlaylistSourceID == Self.commuteID)

        try await appModel.nukeAllData(modelContext: fixture.context)

        #expect(appModel.playback.currentEpisode == nil)
        #expect(appModel.currentPlaylistSourceID == nil)
        #expect(appModel.currentPlaylistSource == nil)
        #expect(appModel.upNextQueue.items.isEmpty)
        #expect(try preferenceValues(forKey: PlaybackRestorePreferenceStore.sourcePlaylistIDKey, in: fixture.container).isEmpty)
    }

    @Test("A data nuke deletes every playlist's Siri donation group")
    func nukeDeletesPlaylistDonationGroups() async throws {
        let recorder = SiriDonationRecorder()
        let fixture = try await makeFixture(siriMediaDiscovery: makeDiscovery(recorder: recorder))
        #expect(fixture.appModel.playlists.playlists.count == 2)

        try await fixture.appModel.nukeAllData(modelContext: fixture.context)

        #expect(Set(recorder.deletedGroupIdentifiers).isSuperset(of: [Self.commuteID, Self.emptyID]))
    }

    @Test("Starting a playlist donates it once as a playlist container, beside the show")
    func playingAPlaylistDonatesItsContainer() async throws {
        let recorder = SiriDonationRecorder()
        let fixture = try await makePlayableFixture(siriMediaDiscovery: makeDiscovery(recorder: recorder))
        let appModel = fixture.appModel

        #expect(appModel.playPlaylist(Self.commuteID, modelContext: fixture.context))
        // The tagged advance plays from the same playlist, so the dedupe key absorbs it.
        #expect(appModel.advanceToNextQueuedEpisode(modelContext: fixture.context))

        #expect(appModel.playback.currentEpisode?.id.rawValue == "third")
        #expect(recorder.donatedGroupIdentifiers == [Self.podcastID, Self.commuteID])
        #expect(recorder.playlistDonations.count == 1)
        let donation = try #require(recorder.playlistDonations.first)
        let intent = try #require(donation.intent as? INPlayMediaIntent)
        let container = try #require(intent.mediaContainer)
        #expect(donation.groupIdentifier == Self.commuteID)
        #expect(container.identifier == Self.commuteID)
        #expect(container.title == "Commute")
        #expect(intent.mediaItems == nil)
    }

    @Test("Deleting a playlist drops its Siri donations only after the store deletes it")
    func deletePlaylistDropsTheDonationGroupOnlyAfterTheStoreSucceeds() async throws {
        let failingRecorder = SiriDonationRecorder()
        let failingSaves = LibrarySaveProbe()
        let failing = try await makeFixture(
            librarySave: failingSaves.save,
            siriMediaDiscovery: makeDiscovery(recorder: failingRecorder)
        )
        failingSaves.failsSaves = true

        #expect(!failing.appModel.deletePlaylist(Self.commuteID, modelContext: failing.context))

        #expect(failingRecorder.deletedGroupIdentifiers.isEmpty)
        #expect(failing.appModel.playlist(Self.commuteID) != nil)
        #expect(failing.appModel.lastPlaylistError?.contains("Simulated playlist save failure") == true)

        let recorder = SiriDonationRecorder()
        let fixture = try await makeFixture(siriMediaDiscovery: makeDiscovery(recorder: recorder))

        #expect(fixture.appModel.deletePlaylist(Self.commuteID, modelContext: fixture.context))

        #expect(recorder.deletedGroupIdentifiers == [Self.commuteID])
        #expect(fixture.appModel.playlist(Self.commuteID) == nil)
    }

    @Test("Renaming a playlist drops its Siri donations only after the store saves, and the next start donates the new name")
    func renamePlaylistDropsTheDonationGroupOnlyAfterTheStoreSucceeds() async throws {
        let failingRecorder = SiriDonationRecorder()
        let failingSaves = LibrarySaveProbe()
        let failing = try await makeFixture(
            librarySave: failingSaves.save,
            siriMediaDiscovery: makeDiscovery(recorder: failingRecorder)
        )
        failingSaves.failsSaves = true

        #expect(!failing.appModel.renamePlaylist(Self.commuteID, to: "Morning", modelContext: failing.context))

        #expect(failingRecorder.deletedGroupIdentifiers.isEmpty)
        #expect(failing.appModel.playlist(Self.commuteID)?.name == "Commute")
        #expect(failing.appModel.lastPlaylistError?.contains("Simulated playlist save failure") == true)

        let recorder = SiriDonationRecorder()
        let fixture = try await makePlayableFixture(siriMediaDiscovery: makeDiscovery(recorder: recorder))
        let appModel = fixture.appModel
        #expect(appModel.playPlaylist(Self.commuteID, modelContext: fixture.context))

        #expect(appModel.renamePlaylist(Self.commuteID, to: "Morning", modelContext: fixture.context))

        #expect(recorder.deletedGroupIdentifiers == [Self.commuteID])
        #expect(appModel.playPlaylist(Self.commuteID, modelContext: fixture.context))
        let titles = recorder.playlistDonations.compactMap { ($0.intent as? INPlayMediaIntent)?.mediaContainer?.title }
        #expect(titles == ["Commute", "Morning"])
    }

    @Test("Playlist play paths skip the phone's Now Playing sheet when asked, and request it by default")
    func playlistPlayPathsSkipThePhoneSheetWhenAsked() async throws {
        let fixture = try await makePlayableFixture()
        let appModel = fixture.appModel
        let context = fixture.context
        let thirdItemID = try itemID(for: "third", in: Self.commuteID, appModel: appModel)

        #expect(appModel.playPlaylist(Self.commuteID, presentsNowPlaying: false, modelContext: context))
        #expect(appModel.playback.currentEpisode?.id.rawValue == "first")
        #expect(appModel.playPlaylistItem(thirdItemID, in: Self.commuteID, presentsNowPlaying: false, modelContext: context))
        #expect(appModel.playback.currentEpisode?.id.rawValue == "third")
        #expect(appModel.playPlaylistEpisode("first", in: Self.commuteID, presentsNowPlaying: false, modelContext: context))
        #expect(appModel.playback.currentEpisode?.id.rawValue == "first")
        // The request is posted from a Task after a yield.
        for _ in 0..<10 {
            await Task.yield()
        }
        #expect(appModel.nowPlayingPresentationRequest == 0)

        #expect(appModel.playPlaylistEpisode("third", in: Self.commuteID, modelContext: context))
        #expect(await waitUntil { appModel.nowPlayingPresentationRequest == 1 })
    }

    @Test("Download All offers only unplayed, resolvable episodes without a completed download, then starts each")
    func downloadAllSkipsPlayedUnresolvableAndCompleted() async throws {
        let directory = try makeTemporaryDirectory()
        let fileStore = EpisodeDownloadFileStore(baseDirectory: directory)
        let downloader = RecordingHangingEpisodeAudioDownloader()
        let fixture = try await makePlayableFixture(
            downloads: DownloadStore(downloader: downloader, fileStore: fileStore)
        )
        let appModel = fixture.appModel
        let context = fixture.context
        try addToCommute(["fourth"], fixture: fixture)
        try insertCompletedDownload(episodeID: "first", writesFile: true, fileStore: fileStore, context: context)
        // A completed record whose file is gone downloads again.
        try insertCompletedDownload(episodeID: "fourth", writesFile: false, fileStore: fileStore, context: context)
        try context.save()
        await appModel.downloads.load(modelContext: context)

        #expect(appModel.playlistDownloadAllCandidates(Self.commuteID).map(\.episodeID) == ["third", "fourth"])
        #expect(appModel.playlistDownloadAllCandidates(Self.emptyID).isEmpty)

        appModel.downloadAllPlaylistEpisodes(Self.commuteID, modelContext: context)

        #expect(await waitUntil { downloader.requestCount == 2 })
        #expect(appModel.downloads.record(for: "third")?.state == .downloading)
        #expect(appModel.downloads.record(for: "fourth")?.state == .downloading)
        #expect(appModel.downloads.record(for: "first")?.state == .completed)
        #expect(appModel.downloads.record(for: "second") == nil)
        // In-flight downloads are not offered again: restarting one would
        // discard its progress.
        #expect(appModel.playlistDownloadAllCandidates(Self.commuteID).isEmpty)
        #expect(appModel.playback.currentEpisode == nil)

        for episodeID in ["third", "fourth"] {
            appModel.downloads.cancelDownload(episodeID: episodeID, modelContext: context)
        }
    }

    @Test("Download All reports the episodes it could not start through the playlist alert")
    func downloadAllSurfacesStartFailures() async throws {
        let directory = try makeTemporaryDirectory()
        let downloader = RecordingHangingEpisodeAudioDownloader()
        let fixture = try await makePlayableFixture(
            downloads: DownloadStore(downloader: downloader, fileStore: EpisodeDownloadFileStore(baseDirectory: directory))
        )
        let appModel = fixture.appModel
        let context = fixture.context
        try addToCommute(["silent"], fixture: fixture)
        #expect(appModel.playlistDownloadAllCandidates(Self.commuteID).map(\.episodeID) == ["first", "third", "silent"])

        #expect(!appModel.downloadAllPlaylistEpisodes(Self.commuteID, modelContext: context))

        #expect(await waitUntil { downloader.requestCount == 2 })
        #expect(appModel.downloads.record(for: "first")?.state == .downloading)
        #expect(appModel.downloads.record(for: "third")?.state == .downloading)
        #expect(appModel.downloads.record(for: "silent")?.state == .failed)
        let reason = EpisodeDownloadError.invalidAudioURL.localizedDescription
        #expect(appModel.lastPlaylistError == "1 of 3 episodes could not be downloaded. \(reason)")

        // The in-flight pair drops out, so the retry fails outright.
        appModel.lastPlaylistError = nil
        #expect(appModel.playlistDownloadAllCandidates(Self.commuteID).map(\.episodeID) == ["silent"])
        #expect(!appModel.downloadAllPlaylistEpisodes(Self.commuteID, modelContext: context))
        #expect(appModel.lastPlaylistError == "1 episode could not be downloaded. \(reason)")
        #expect(downloader.requestCount == 2)

        for episodeID in ["first", "third"] {
            appModel.downloads.cancelDownload(episodeID: episodeID, modelContext: context)
        }
    }

    @Test("Download All failure copy agrees in number")
    func downloadAllFailureCopy() {
        #expect(
            OpenCastAppModel.downloadAllFailureMessage(failureCount: 3, candidateCount: 3, reason: nil)
                == "3 episodes could not be downloaded."
        )
        #expect(
            OpenCastAppModel.downloadAllFailureMessage(failureCount: 2, candidateCount: 5, reason: "Disk full.")
                == "2 of 5 episodes could not be downloaded. Disk full."
        )
    }

    @Test("Playlist source copy agrees in number and keeps names verbatim")
    func playlistSourceCopy() {
        #expect(PlaylistPlaybackSourceText.miniPlayerRemainingSegment(remainingCount: 1) == " · 1 left")
        #expect(
            PlaylistPlaybackSourceText.miniPlayerAccessibilityValue(title: "Episode first", name: "Commute", remainingCount: 2)
                == "Episode first, playing from Commute, 2 left"
        )
        #expect(
            PlaylistPlaybackSourceText.miniPlayerAccessibilityValue(title: "A *bold* title", name: "Commute", remainingCount: 0)
                == "A *bold* title, playing from Commute"
        )
        #expect(PlaylistPlaybackSourceText.upNextSubtitle(name: "Commute", remainingCount: 3) == "From Commute · 3 left")
        #expect(PlaylistPlaybackSourceText.upNextSubtitle(name: "Commute", remainingCount: 0).isEmpty)
        #expect(PlaylistPlaybackSourceText.utilityValue(name: "Commute", remainingCount: 1) == "1 episode left in Commute")
        #expect(PlaylistPlaybackSourceText.utilityValue(name: "Commute", remainingCount: 3) == "3 episodes left in Commute")
        #expect(
            PlaylistPlaybackSourceText.utilityValue(name: "My *Best* _Mix_ [a](b)", remainingCount: 2)
                == "2 episodes left in My *Best* _Mix_ [a](b)"
        )
        #expect(
            PlaylistPlaybackSourceText.upNextFooter(name: "Commute")
                == "Play Next puts an episode ahead of the rest of Commute."
        )
        #expect(PlaylistPlaybackSourceText.pillLabel(name: "Commute") == "Playing from Commute")
        #expect(PlaylistPlaybackSourceText.showPlaylistMenuTitle(name: "Commute") == "Show Commute")
    }

    @Test("A chosen playlist sort order survives a relaunch")
    func sortOrderReloadsThroughCoreStoreLoad() async throws {
        let fixture = try await makeFixture()
        #expect(fixture.appModel.playlistDisplaySettings.sortOrder == .recentlyUpdated)

        let changed = fixture.appModel.setPlaylistSortOrder(.name, modelContext: fixture.context)

        #expect(changed)
        #expect(fixture.appModel.playlists.sortOrder == .name)
        #expect(fixture.appModel.lastPlaylistError == nil)
        let relaunched = try makeAppModel(library: LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory()))
        await relaunched.ensureCoreStoresLoaded(modelContext: ModelContext(fixture.container))
        #expect(relaunched.playlistDisplaySettings.sortOrder == .name)
        #expect(relaunched.playlists.sortOrder == .name)
    }

    @Test("A failed sort-order save keeps the order and surfaces the error")
    func failedSortOrderSaveSurfacesError() async throws {
        let fixture = try await makeFixture(
            playlistDisplaySettings: PlaylistDisplaySettingsStore(save: { _ in throw PlaylistSaveFailure() })
        )
        let appModel = fixture.appModel

        let changed = appModel.setPlaylistSortOrder(.name, modelContext: fixture.context)

        #expect(!changed)
        #expect(appModel.playlistDisplaySettings.sortOrder == .recentlyUpdated)
        #expect(appModel.playlists.sortOrder == .recentlyUpdated)
        #expect(appModel.lastPlaylistError?.contains("Unable to update playlist sort order") == true)
        #expect(appModel.playlistDisplaySettings.lastErrorMessage == nil)
        let reloaded = PlaylistDisplaySettingsStore()
        reloaded.load(modelContext: ModelContext(fixture.container))
        #expect(reloaded.sortOrder == .recentlyUpdated)
    }

    /// An episode outside every playlist, queued to show what Play replaces.
    private func unrelatedSnapshot() -> EpisodeListItemSnapshot {
        EpisodeListItemSnapshot.fixture(
            episodeID: "unrelated",
            podcastID: Self.otherPodcastID,
            audioURL: "https://example.com/unrelated.mp3",
            guid: "unrelated"
        )
    }

    /// The commute playlist as [unplayed first, played second, unresolvable
    /// elsewhere, unplayed third].
    private func makePlayableFixture(
        upNextQueue: UpNextQueueStore = UpNextQueueStore(),
        downloads: DownloadStore? = nil,
        libraryNow: @escaping () -> Date = { .now },
        siriMediaDiscovery: SiriMediaDiscovery = SiriMediaDiscovery()
    ) async throws -> (
        appModel: OpenCastAppModel,
        context: ModelContext,
        container: ModelContainer,
        cache: SQLiteLocalLibraryCacheStore
    ) {
        let fixture = try await makeFixture(
            upNextQueue: upNextQueue,
            downloads: downloads,
            libraryNow: libraryNow,
            siriMediaDiscovery: siriMediaDiscovery
        )
        let appModel = fixture.appModel
        let context = fixture.context
        let third = try #require(appModel.episodeSnapshot(for: "third"))
        let addedCount = appModel.performPlaylistMutation {
            appModel.playlists.add([third], to: Self.commuteID, modelContext: context)
        }
        #expect(addedCount == 1)
        let second = try #require(appModel.episodeSnapshot(for: "second"))
        let markedPlayed = appModel.markEpisodePlayed(second, modelContext: context)
        #expect(markedPlayed)
        #expect(appModel.library.progressRecord(for: "second")?.isPlayed == true)
        #expect(
            appModel.playlists.itemsByPlaylistID[Self.commuteID]?.map(\.episodeID)
                == ["first", "second", "elsewhere", "third"]
        )
        #expect(appModel.lastPlaylistError == nil)
        return fixture
    }

    @Test("Each playlist mutation through the app model takes exactly one synced-store credit")
    func everyPlaylistMutationTakesOneCredit() async throws {
        let fixture = try await makeFixture()
        let appModel = fixture.appModel
        let context = fixture.context
        let library = appModel.library

        var credits = library.syncedStoreSelfSaveCount
        let created = appModel.performPlaylistMutation {
            appModel.playlists.create(name: "Walks", kind: .manual, modelContext: context)
        }
        #expect(created != nil)
        #expect(library.syncedStoreSelfSaveCount == credits + 1)

        let smart = try createSmartPlaylist(.default, appModel: appModel, context: context)
        credits = library.syncedStoreSelfSaveCount
        let didSetRule = appModel.performPlaylistMutation {
            appModel.playlists.setRule(
                PlaylistRule(podcastIDs: [Self.podcastID], status: .all),
                for: smart.playlistID,
                modelContext: context
            )
        }
        #expect(didSetRule)
        #expect(library.syncedStoreSelfSaveCount == credits + 1)

        credits = library.syncedStoreSelfSaveCount
        #expect(appModel.renamePlaylist(Self.commuteID, to: "Morning", modelContext: context))
        #expect(library.syncedStoreSelfSaveCount == credits + 1)

        credits = library.syncedStoreSelfSaveCount
        let didHidePlayed = appModel.performPlaylistMutation {
            appModel.playlists.setHidesPlayed(true, for: Self.commuteID, modelContext: context)
        }
        #expect(didHidePlayed)
        #expect(library.syncedStoreSelfSaveCount == credits + 1)

        credits = library.syncedStoreSelfSaveCount
        try addToCommute(["third"], fixture: fixture)
        #expect(library.syncedStoreSelfSaveCount == credits + 1)

        credits = library.syncedStoreSelfSaveCount
        let didRemove = appModel.performPlaylistMutation {
            appModel.playlists.remove(itemIDs: [Self.commuteItemIDs[0]], from: Self.commuteID, modelContext: context)
        }
        #expect(didRemove)
        #expect(library.syncedStoreSelfSaveCount == credits + 1)

        credits = library.syncedStoreSelfSaveCount
        let didMove = appModel.performPlaylistMutation {
            appModel.playlists.move(fromOffsets: IndexSet(integer: 1), toOffset: 0, in: Self.commuteID, modelContext: context)
        }
        #expect(didMove)
        #expect(library.syncedStoreSelfSaveCount == credits + 1)

        let dated = try #require(created)
        let datedAdded = appModel.performPlaylistMutation {
            appModel.playlists.add(
                [
                    datedEpisode("later", publishedAt: Date(timeIntervalSince1970: 1_775_000_600)),
                    datedEpisode("earlier", publishedAt: Date(timeIntervalSince1970: 1_775_000_000))
                ],
                to: dated.playlistID,
                modelContext: context
            )
        }
        #expect(datedAdded == 2)
        credits = library.syncedStoreSelfSaveCount
        let didSort = appModel.performPlaylistMutation {
            appModel.playlists.sortItems(in: dated.playlistID, by: .oldestFirst, modelContext: context)
        }
        #expect(didSort)
        #expect(appModel.playlists.itemsByPlaylistID[dated.playlistID]?.map(\.episodeID) == ["earlier", "later"])
        #expect(library.syncedStoreSelfSaveCount == credits + 1)

        credits = library.syncedStoreSelfSaveCount
        #expect(appModel.deletePlaylist(Self.commuteID, modelContext: context))
        #expect(library.syncedStoreSelfSaveCount == credits + 1)
        #expect(appModel.lastPlaylistError == nil)
    }

    @Test("Rows inserted, renamed and deleted behind the store reach memory through the synced-change reload")
    func syncedChangeReloadBringsRemoteRowsIntoMemory() async throws {
        let fixture = try await makeFixture()
        let appModel = fixture.appModel
        // The store's own context, saved plainly: an import changes rows
        // without going through the store.
        let importContext = fixture.context
        let importedAt = Date(timeIntervalSince1970: 1_775_003_600)
        importContext.insert(
            PlaylistRecord(playlistID: "imported", name: "From Another Device", createdAt: importedAt, updatedAt: importedAt)
        )
        importContext.insert(
            PlaylistItemRecord(
                itemID: "imported-item",
                playlistID: "imported",
                episodeID: "third",
                podcastID: Self.podcastID,
                sortKey: PlaylistSortKey.renumbered(count: 1)[0],
                addedAt: importedAt,
                updatedAt: importedAt,
                episodeTitle: "Episode third",
                podcastTitle: "Playlist Show"
            )
        )
        for record in try importContext.fetch(FetchDescriptor<PlaylistRecord>()) {
            if record.playlistID == Self.emptyID {
                record.name = "Renamed Elsewhere"
            } else if record.playlistID == Self.commuteID {
                importContext.delete(record)
            }
        }
        for record in try importContext.fetch(FetchDescriptor<PlaylistItemRecord>()) where record.playlistID == Self.commuteID {
            importContext.delete(record)
        }
        try importContext.save()
        #expect(appModel.playlist(Self.commuteID) != nil)

        let change = appModel.reloadPlaylistsAfterSyncedChange(modelContext: fixture.context)

        #expect(change.didChange)
        #expect(!change.needsRepair)
        #expect(change.removedPlaylistIDs == [Self.commuteID])
        #expect(change.renamedPlaylistIDs == [Self.emptyID])
        #expect(Set(appModel.playlists.playlists.map(\.playlistID)) == [Self.emptyID, "imported"])
        #expect(appModel.playlist(Self.emptyID)?.name == "Renamed Elsewhere")
        #expect(appModel.playlists.itemsByPlaylistID["imported"]?.map(\.itemID) == ["imported-item"])
        #expect(appModel.playlists.itemsByPlaylistID[Self.commuteID] == nil)
        #expect(appModel.lastPlaylistError == nil)

        let quiet = appModel.reloadPlaylistsAfterSyncedChange(modelContext: fixture.context)
        #expect(quiet == PlaylistReloadChange())
    }

    @Test("A remote delete and a remote rename each drop the playlist's Siri donation group")
    func syncedChangeReloadDropsDonationGroups() async throws {
        let recorder = SiriDonationRecorder()
        let fixture = try await makeFixture(siriMediaDiscovery: makeDiscovery(recorder: recorder))
        let importContext = fixture.context
        for record in try importContext.fetch(FetchDescriptor<PlaylistRecord>()) {
            if record.playlistID == Self.emptyID {
                record.name = "Renamed Elsewhere"
            } else if record.playlistID == Self.commuteID {
                importContext.delete(record)
            }
        }
        try importContext.save()

        fixture.appModel.reloadPlaylistsAfterSyncedChange(modelContext: fixture.context)

        #expect(recorder.deletedGroupIdentifiers.sorted() == [Self.commuteID, Self.emptyID])

        fixture.appModel.reloadPlaylistsAfterSyncedChange(modelContext: fixture.context)

        #expect(recorder.deletedGroupIdentifiers.count == 2)
    }

    @Test("A repair that merged playlist twins is followed by a reload that lists the merged playlist")
    func repairOfPlaylistTwinsReloadsPlaylists() async throws {
        let fixture = try await makeFixture()
        let appModel = fixture.appModel
        let newer = Date(timeIntervalSince1970: 1_775_003_600)
        // Loses the identity to the row the fixture seeded but carries the
        // newest content, so only a reload after the merge shows its name.
        fixture.context.insert(
            PlaylistRecord(
                playlistID: Self.commuteID,
                name: "Commute Elsewhere",
                createdAt: newer,
                updatedAt: newer,
                dedupeUUID: "zzzzzzzz-0000-0000-0000-000000000000"
            )
        )
        try fixture.context.save()
        #expect(appModel.playlist(Self.commuteID)?.name == "Commute")

        let result = await appModel.repairSyncDuplicates(modelContext: fixture.context)

        #expect(result?.playlistRowsChanged == true)
        #expect(appModel.playlists.playlists.filter { $0.playlistID == Self.commuteID }.count == 1)
        #expect(appModel.playlist(Self.commuteID)?.name == "Commute Elsewhere")
        #expect(appModel.playlists.itemsByPlaylistID[Self.commuteID]?.map(\.itemID) == Self.commuteItemIDs)
        let stored = try ModelContext(fixture.container).fetch(FetchDescriptor<PlaylistRecord>())
        #expect(stored.filter { $0.playlistID == Self.commuteID }.count == 1)
    }

    @Test("After a committed feed-address move a synced-change reload reports no change")
    func syncedChangeReloadAfterFeedMoveIsQuiet() async throws {
        let fixture = try await makeFeedMoveFixture()
        let appModel = try makeAppModel(library: fixture.makeLibrary())
        await appModel.ensureCoreStoresLoaded(modelContext: fixture.context)
        try await appModel.library.migrateSubscription(
            from: Self.departedFeedURL,
            toFeedURL: #require(URL(string: Self.movedFeedURL)),
            modelContext: fixture.context
        )
        let itemsAfterMove = appModel.playlists.itemsByPlaylistID

        let change = appModel.reloadPlaylistsAfterSyncedChange(modelContext: fixture.context)

        #expect(change == PlaylistReloadChange())
        #expect(appModel.playlists.itemsByPlaylistID == itemsAfterMove)
    }

    @Test("Playlists an earlier build kept on the device are listed after loading and the copy is marked done")
    func legacyLocalPlaylistsAreMigratedOnLoad() async throws {
        let suiteName = "OpenCastAppModelPlaylistTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let cache = SQLiteLocalLibraryCacheStore.inMemory()
        try await cache.upsertCache(from: feedSnapshot(), refreshedAt: .now)
        let createdAt = Date(timeIntervalSince1970: 1_775_000_000)
        let snapshot = LegacyLocalPlaylistSnapshot(
            playlists: [
                LegacyLocalPlaylistSnapshot.Playlist(
                    playlistID: "kept-locally",
                    name: "Kept Locally",
                    kindRawValue: "manual",
                    ruleJSON: nil,
                    hidesPlayed: false,
                    tintKey: nil,
                    originRawValue: "user",
                    createdAt: createdAt,
                    updatedAt: createdAt
                )
            ],
            items: [
                LegacyLocalPlaylistSnapshot.Item(
                    itemID: "kept-locally-item",
                    playlistID: "kept-locally",
                    episodeID: "first",
                    podcastID: Self.podcastID,
                    sortKey: PlaylistSortKey.renumbered(count: 1)[0],
                    addedAt: createdAt,
                    updatedAt: createdAt,
                    episodeTitle: "Episode first",
                    podcastTitle: "Playlist Show",
                    artworkURL: nil,
                    audioURL: "https://example.com/first.mp3",
                    duration: 60,
                    publishedAt: nil
                )
            ]
        )
        let appModel = try makeAppModel(
            library: LibraryStore(localCache: cache),
            legacyLocalPlaylists: snapshot,
            playlistMigrationDefaults: defaults
        )

        await appModel.ensureCoreStoresLoaded(modelContext: context)

        #expect(appModel.playlists.playlists.map(\.playlistID) == ["kept-locally"])
        #expect(appModel.playlist("kept-locally")?.name == "Kept Locally")
        #expect(appModel.playlists.itemsByPlaylistID["kept-locally"]?.map(\.itemID) == ["kept-locally-item"])
        #expect(appModel.lastPlaylistError == nil)
        #expect(defaults.bool(forKey: PlaylistLocalStoreMigration.completedDefaultsKey))
        let stored = try ModelContext(container).fetch(FetchDescriptor<PlaylistRecord>())
        #expect(stored.map(\.playlistID) == ["kept-locally"])
    }

    @Test("An app model built without locally stored playlists leaves the copy flag untouched")
    func missingLegacySnapshotLeavesFlagUntouched() async throws {
        let suiteName = "OpenCastAppModelPlaylistTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let appModel = try makeAppModel(
            library: LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory()),
            playlistMigrationDefaults: defaults
        )

        await appModel.ensureCoreStoresLoaded(modelContext: context)

        #expect(defaults.object(forKey: PlaylistLocalStoreMigration.completedDefaultsKey) == nil)
        #expect(appModel.playlists.playlists.isEmpty)
        #expect(appModel.lastPlaylistError == nil)
    }

    private func datedEpisode(_ episodeID: String, publishedAt: Date) -> EpisodeListItemSnapshot {
        .fixture(
            episodeID: episodeID,
            podcastID: Self.podcastID,
            podcastTitle: "Playlist Show",
            title: "Episode \(episodeID)",
            publishedAt: publishedAt,
            audioURL: "https://example.com/\(episodeID).mp3",
            guid: episodeID
        )
    }

    private func makeFixture(
        upNextQueue: UpNextQueueStore = UpNextQueueStore(),
        playlistDisplaySettings: PlaylistDisplaySettingsStore = PlaylistDisplaySettingsStore(),
        downloads: DownloadStore? = nil,
        libraryNow: @escaping () -> Date = { .now },
        librarySave: @escaping (ModelContext) throws -> Void = { try $0.save() },
        siriMediaDiscovery: SiriMediaDiscovery = SiriMediaDiscovery()
    ) async throws -> (
        appModel: OpenCastAppModel,
        context: ModelContext,
        container: ModelContainer,
        cache: SQLiteLocalLibraryCacheStore
    ) {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let cache = SQLiteLocalLibraryCacheStore.inMemory()
        try await cache.upsertCache(from: feedSnapshot(), refreshedAt: .now)
        context.insert(SubscriptionRecord(feedURL: Self.podcastID, title: "Playlist Show"))
        seedPlaylists(in: context)
        try context.save()

        let appModel = try makeAppModel(
            library: LibraryStore(
                localCache: cache,
                savePlaybackSkipSettingsModelContext: librarySave,
                now: libraryNow
            ),
            upNextQueue: upNextQueue,
            playlistDisplaySettings: playlistDisplaySettings,
            downloads: downloads,
            siriMediaDiscovery: siriMediaDiscovery
        )
        await appModel.ensureCoreStoresLoaded(modelContext: context)
        return (appModel, context, container, cache)
    }

    private func makeAppModel(
        library: LibraryStore,
        upNextQueue: UpNextQueueStore = UpNextQueueStore(),
        playlistDisplaySettings: PlaylistDisplaySettingsStore = PlaylistDisplaySettingsStore(),
        downloads: DownloadStore? = nil,
        siriMediaDiscovery: SiriMediaDiscovery = SiriMediaDiscovery(),
        legacyLocalPlaylists: LegacyLocalPlaylistSnapshot? = nil,
        playlistMigrationDefaults: UserDefaults = .standard
    ) throws -> OpenCastAppModel {
        let temporaryDirectory = try makeTemporaryDirectory()
        let applicationSupportDirectory = temporaryDirectory.appending(
            path: "ApplicationSupport",
            directoryHint: .isDirectory
        )
        return OpenCastAppModel(
            cacheController: OpenCastCacheController(
                rootDirectory: temporaryDirectory.appending(path: "Caches", directoryHint: .isDirectory)
            ),
            library: library,
            downloads: downloads
                ?? DownloadStore(fileStore: EpisodeDownloadFileStore(baseDirectory: applicationSupportDirectory)),
            transcriptions: EpisodeTranscriptionStore(
                fileStore: EpisodeTranscriptFileStore(baseDirectory: applicationSupportDirectory)
            ),
            adAnalyses: EpisodeAdAnalysisStore(
                fileStore: EpisodeAdAnalysisFileStore(baseDirectory: applicationSupportDirectory)
            ),
            upNextQueue: upNextQueue,
            playlistDisplaySettings: playlistDisplaySettings,
            syncStatus: SyncStatusStore(accountStatusProvider: AvailableCloudKitAccountStatusProvider()),
            allowsAutomaticFeedRefresh: false,
            siriMediaDiscovery: siriMediaDiscovery,
            legacyLocalPlaylists: legacyLocalPlaylists,
            playlistMigrationDefaults: playlistMigrationDefaults
        )
    }

    private func addToCommute(
        _ episodeIDs: [String],
        fixture: (
            appModel: OpenCastAppModel,
            context: ModelContext,
            container: ModelContainer,
            cache: SQLiteLocalLibraryCacheStore
        )
    ) throws {
        let appModel = fixture.appModel
        var episodes: [EpisodeListItemSnapshot] = []
        for episodeID in episodeIDs {
            let episode = try #require(appModel.episodeSnapshot(for: episodeID))
            episodes.append(episode)
        }
        let addedCount = appModel.performPlaylistMutation {
            appModel.playlists.add(episodes, to: Self.commuteID, modelContext: fixture.context)
        }
        #expect(addedCount == episodes.count)
    }

    private func createSmartPlaylist(
        _ rule: PlaylistRule,
        name: String = "Smart",
        appModel: OpenCastAppModel,
        context: ModelContext
    ) throws -> PlaylistSummary {
        let created = appModel.performPlaylistMutation {
            appModel.playlists.create(name: name, kind: .smart, rule: rule, modelContext: context)
        }
        #expect(appModel.lastPlaylistError == nil)
        return try #require(created)
    }

    private func playlistSummary(_ playlistID: String, appModel: OpenCastAppModel) throws -> PlaylistSummary {
        try #require(appModel.playlists.playlists.first(where: { $0.playlistID == playlistID }))
    }

    private func itemID(for episodeID: String, in playlistID: String, appModel: OpenCastAppModel) throws -> String {
        try #require(
            appModel.playlists.itemsByPlaylistID[playlistID]?.first { $0.episodeID == episodeID }?.itemID
        )
    }

    private func preferenceValues(forKey key: String, in container: ModelContainer) throws -> [String] {
        try ModelContext(container).fetch(
            FetchDescriptor<LocalPreferenceRecord>(
                predicate: #Predicate { record in
                    record.key == key
                }
            )
        ).map(\.value)
    }

    private func insertCompletedDownload(
        episodeID: String,
        writesFile: Bool,
        fileStore: EpisodeDownloadFileStore,
        context: ModelContext
    ) throws {
        let sourceAudioURL = try #require(URL(string: "https://example.com/\(episodeID).mp3"))
        let relativePath = fileStore.relativePath(episodeID: episodeID, sourceAudioURL: sourceAudioURL)
        let data = Data("downloaded \(episodeID)".utf8)
        if writesFile {
            try fileStore.prepareDownloadsDirectory()
            try data.write(to: fileStore.fileURL(relativePath: relativePath), options: .atomic)
        }
        context.insert(
            EpisodeDownloadRecord(
                episodeID: episodeID,
                podcastID: Self.podcastID,
                sourceAudioURL: sourceAudioURL.absoluteString,
                localRelativePath: relativePath,
                state: .completed,
                bytesReceived: Int64(data.count),
                bytesExpected: Int64(data.count)
            )
        )
    }

    private func makeDiscovery(recorder: SiriDonationRecorder) -> SiriMediaDiscovery {
        SiriMediaDiscovery(
            userContextPublisher: { _ in },
            interactionDonator: { recorder.donatedInteractions.append($0) },
            interactionGroupDeleter: { recorder.deletedGroupIdentifiers.append($0) }
        )
    }

    private func seedPlaylists(in context: ModelContext) {
        let createdAt = Date(timeIntervalSince1970: 1_775_000_000)
        context.insert(
            PlaylistRecord(
                playlistID: Self.commuteID,
                name: "Commute",
                createdAt: createdAt,
                updatedAt: createdAt
            )
        )
        context.insert(
            PlaylistRecord(
                playlistID: Self.emptyID,
                name: "Empty",
                createdAt: createdAt.addingTimeInterval(-60),
                updatedAt: createdAt.addingTimeInterval(-60)
            )
        )
        let sortKeys = PlaylistSortKey.renumbered(count: Self.commuteItemIDs.count)
        let members: [(episodeID: String, podcastID: String, podcastTitle: String)] = [
            ("first", Self.podcastID, "Playlist Show"),
            ("second", Self.podcastID, "Playlist Show"),
            ("elsewhere", Self.otherPodcastID, "Other Show")
        ]
        for (index, member) in members.enumerated() {
            let addedAt = createdAt.addingTimeInterval(Double(index))
            context.insert(
                PlaylistItemRecord(
                    itemID: Self.commuteItemIDs[index],
                    playlistID: Self.commuteID,
                    episodeID: member.episodeID,
                    podcastID: member.podcastID,
                    sortKey: sortKeys[index],
                    addedAt: addedAt,
                    updatedAt: addedAt,
                    episodeTitle: "Episode \(member.episodeID)",
                    podcastTitle: member.podcastTitle,
                    audioURL: "https://example.com/\(member.episodeID).mp3",
                    duration: 60
                )
            )
        }
    }

    private func feedSnapshot() throws -> FeedSnapshot {
        let feedURL = try #require(URL(string: Self.podcastID))
        let podcast = Podcast(
            id: PodcastID(rawValue: Self.podcastID),
            feedURL: feedURL,
            title: "Playlist Show"
        )
        return FeedSnapshot(
            podcast: podcast,
            // "silent" has no audio, so starting it throws.
            episodes: ["first", "second", "third", "fourth", "silent"].map { id in
                Episode(
                    id: EpisodeID(rawValue: id),
                    podcastID: podcast.id,
                    podcastTitle: podcast.title,
                    title: "Episode \(id)",
                    duration: 60,
                    audioURL: id == "silent" ? nil : URL(string: "https://example.com/\(id).mp3"),
                    guid: id
                )
            }
        )
    }

    /// Two playlists over a show about to move: one holding only the
    /// departed episode, one holding the departed and the successor.
    @MainActor
    private struct FeedMoveFixture {
        let container: ModelContainer
        let context: ModelContext
        let cache: SQLiteLocalLibraryCacheStore
        let departedSnapshot: FeedSnapshot
        let movedSnapshot: FeedSnapshot

        var departedEpisodeID: String {
            departedSnapshot.episodes[0].id.rawValue
        }

        var successorEpisodeID: String {
            movedSnapshot.episodes[0].id.rawValue
        }

        func makeLibrary(
            save: @escaping (ModelContext) throws -> Void = { try $0.save() }
        ) -> LibraryStore {
            LibraryStore(
                feedService: SingleSnapshotStubFeedService(
                    snapshotsByURL: [OpenCastAppModelPlaylistTests.movedFeedURL: movedSnapshot]
                ),
                localCache: cache,
                savePlaybackSkipSettingsModelContext: save
            )
        }
    }

    private func makeFeedMoveFixture() async throws -> FeedMoveFixture {
        let departedSnapshot = movedShowSnapshot(feedURL: Self.departedFeedURL)
        let movedSnapshot = movedShowSnapshot(feedURL: Self.movedFeedURL)
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let cache = SQLiteLocalLibraryCacheStore.inMemory()
        try await cache.upsertCache(from: departedSnapshot, refreshedAt: .now)
        context.insert(SubscriptionRecord(feedURL: Self.departedFeedURL, title: "Moved Show"))
        let createdAt = Date(timeIntervalSince1970: 1_775_000_000)
        let members: [(playlistID: String, itemID: String, snapshot: FeedSnapshot)] = [
            ("departed-only", "departed-only-item", departedSnapshot),
            ("both-episodes", "both-departed-item", departedSnapshot),
            ("both-episodes", "both-successor-item", movedSnapshot)
        ]
        for (index, playlistID) in ["departed-only", "both-episodes"].enumerated() {
            let updatedAt = createdAt.addingTimeInterval(Double(index))
            context.insert(
                PlaylistRecord(
                    playlistID: playlistID,
                    name: playlistID,
                    createdAt: updatedAt,
                    updatedAt: updatedAt
                )
            )
        }
        let sortKeys = PlaylistSortKey.renumbered(count: members.count)
        for (index, member) in members.enumerated() {
            let episode = member.snapshot.episodes[0]
            context.insert(
                PlaylistItemRecord(
                    itemID: member.itemID,
                    playlistID: member.playlistID,
                    episodeID: episode.id.rawValue,
                    podcastID: member.snapshot.podcast.id.rawValue,
                    sortKey: sortKeys[index],
                    addedAt: createdAt,
                    updatedAt: createdAt,
                    episodeTitle: episode.title,
                    podcastTitle: episode.podcastTitle,
                    duration: episode.duration
                )
            )
        }
        try context.save()
        return FeedMoveFixture(
            container: container,
            context: context,
            cache: cache,
            departedSnapshot: departedSnapshot,
            movedSnapshot: movedSnapshot
        )
    }

    /// The same guid under two feed URLs yields two episode IDs, which is the
    /// pair identity reconciliation matches on a feed-address move.
    private func movedShowSnapshot(feedURL: String) -> FeedSnapshot {
        let url = URL(string: feedURL)!
        let audioURL = URL(string: "https://cdn.example.com/playlist-moved.mp3")
        let publishedAt = Date(timeIntervalSince1970: 1_700_000_100)
        let podcastID = URLCanonicalizer.podcastID(for: url)
        return FeedSnapshot(
            podcast: Podcast(id: podcastID, feedURL: url, title: "Moved Show"),
            episodes: [
                Episode(
                    id: EpisodeIdentity.makeID(
                        feedURL: url,
                        guid: "moved-guid",
                        audioURL: audioURL,
                        title: "Moved Episode",
                        publishedAt: publishedAt
                    ),
                    podcastID: podcastID,
                    podcastTitle: "Moved Show",
                    title: "Moved Episode",
                    publishedAt: publishedAt,
                    duration: 120,
                    audioURL: audioURL,
                    guid: "moved-guid"
                )
            ]
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "OpenCastAppModelPlaylistTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private struct PlaylistSaveFailure: LocalizedError {
    var errorDescription: String? { "Simulated playlist save failure" }
}

/// Fails any Up Next save that inserts one episode's row, so a batch holding
/// that episode fails as a whole regardless of how many saves precede it.
private final class UpNextSaveProbe {
    var failingEpisodeID: String?

    func save(_ context: ModelContext) throws {
        if let failingEpisodeID,
           context.insertedModelsArray.contains(where: {
               ($0 as? UpNextQueueItemRecord)?.episodeID == failingEpisodeID
           }) {
            throw PlaylistSaveFailure()
        }
        try context.save()
    }
}

@MainActor
private final class SiriDonationRecorder {
    var donatedInteractions: [INInteraction] = []
    var deletedGroupIdentifiers: [String] = []

    var donatedGroupIdentifiers: [String] {
        donatedInteractions.map { $0.groupIdentifier ?? "" }
    }

    var playlistDonations: [INInteraction] {
        donatedInteractions.filter { ($0.intent as? INPlayMediaIntent)?.mediaContainer?.type == .podcastPlaylist }
    }
}

/// Stands in for the library's synced-store save so one migration save can
/// be made to fail after the identity applier has run.
private final class LibrarySaveProbe {
    var failsSaves = false

    func save(_ context: ModelContext) throws {
        if failsSaves {
            throw PlaylistSaveFailure()
        }
        try context.save()
    }
}
