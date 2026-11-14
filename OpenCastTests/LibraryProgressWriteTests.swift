import Foundation
import OpenCastCore
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Library progress writes")
struct LibraryProgressWriteTests {
    /// Background playback flushes skip the observable refresh so a
    /// non-visible scene never invalidates rows; the row must still be saved
    /// and credited, and the next progress refetch publishes it.
    @Test("A write that skips the observable refresh stays invisible until the next progress refetch")
    func unobservedWriteStaysInvisibleUntilRefetch() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory())
        let episodeID = "unobserved-episode"
        let podcastID = "https://example.com/unobserved.xml"
        await store.load(modelContext: context)

        #expect(store.updateProgress(
            episodeID: episodeID,
            podcastID: podcastID,
            position: 30,
            duration: 120,
            modelContext: context,
            refreshObservableProgress: false
        ))

        #expect(try context.fetch(FetchDescriptor<EpisodeProgressRecord>()).count == 1)
        #expect(store.syncedStoreSelfSaveCount == 1)
        #expect(store.progressRecord(for: episodeID) == nil)
        #expect(store.progressRecords.isEmpty)

        store.refreshProgressRecords(modelContext: context)

        #expect(store.progressRecord(for: episodeID)?.position == 30)
        #expect(store.progressRecords.map(\.episodeID) == [episodeID])
        #expect(store.syncedStoreSelfSaveCount == 1)
        #expect(store.lastErrorMessage == nil)
    }

    /// Smart playlists key their evaluations on `progressChangeRevision`.
    /// A status change saved while the observable refresh is suppressed (a
    /// boundary flush with Now Playing presented) must reach that token once
    /// suppression ends, even though the next observable write only sees the
    /// already-updated row.
    @Test("A suppressed status change reaches the progress change token with the next observable write")
    func suppressedStatusChangeReachesProgressChangeToken() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory())
        let episodeID = "suppressed-status-episode"
        let podcastID = "https://example.com/suppressed-status.xml"
        await store.load(modelContext: context)
        store.updateProgress(
            episodeID: episodeID,
            podcastID: podcastID,
            position: 0,
            duration: 600,
            modelContext: context
        )
        let published = store.progressChangeRevision

        store.updateProgress(
            episodeID: episodeID,
            podcastID: podcastID,
            position: 10,
            duration: 600,
            modelContext: context,
            refreshObservableProgress: false
        )
        #expect(store.progressChangeRevision == published)

        store.updateProgress(
            episodeID: episodeID,
            podcastID: podcastID,
            position: 20,
            duration: 600,
            modelContext: context
        )
        #expect(store.progressChangeRevision != published)
        #expect(store.progressRecord(for: episodeID)?.position == 20)
        #expect(store.lastErrorMessage == nil)
    }

    @Test("An observable write publishes the record immediately")
    func observableWritePublishesImmediately() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory())
        let episodeID = "observed-episode"
        let podcastID = "https://example.com/observed.xml"
        await store.load(modelContext: context)

        #expect(store.updateProgress(
            episodeID: episodeID,
            podcastID: podcastID,
            position: 45,
            duration: 120,
            modelContext: context
        ))

        #expect(store.progressRecord(for: episodeID)?.position == 45)
        #expect(store.progressRecords.map(\.episodeID) == [episodeID])
        #expect(store.syncedStoreSelfSaveCount == 1)
    }

    // MARK: - Archive

    private static let archiveFeedURL = "https://example.com/archive.xml"
    /// The same show under a raw spelling that canonicalizes to the feed URL.
    private static let variantFeedURL = "https://example.com/archive.xml/"
    private static let longAgo = Date(timeIntervalSince1970: 1_000_000)

    @Test("Archiving an episode with no progress inserts a row with no listening, and unarchiving keeps the row")
    func archiveInsertsRowAndUnarchiveClearsTheField() async throws {
        let fixture = try await makeArchiveFixture()
        let store = fixture.store
        let episode = try fixture.episode("archive-1")

        #expect(store.archive(episode, modelContext: fixture.context))

        let record = try #require(store.progressRecord(for: episode.episodeID))
        #expect(try fixture.context.fetch(FetchDescriptor<EpisodeProgressRecord>()).count == 1)
        #expect(record.podcastID == Self.archiveFeedURL)
        #expect(record.position == 0)
        #expect(record.duration == nil)
        #expect(!record.isPlayed)
        #expect(record.archivedAt != nil)
        #expect(!store.progressSummary(for: episode).isCompleted)
        #expect(store.archivedEpisodeIDs == [episode.episodeID])
        #expect(store.isArchived(episodeID: episode.episodeID))
        #expect(store.syncedStoreSelfSaveCount == 1)

        record.updatedAt = Self.longAgo
        try fixture.context.save()
        #expect(store.unarchive(episode, modelContext: fixture.context))

        #expect(store.progressRecord(for: episode.episodeID) === record)
        #expect(try fixture.context.fetch(FetchDescriptor<EpisodeProgressRecord>()).count == 1)
        #expect(record.archivedAt == nil)
        #expect(record.updatedAt > Self.longAgo)
        #expect(store.archivedEpisodeIDs.isEmpty)
        #expect(!store.isArchived(episodeID: episode.episodeID))
        #expect(store.syncedStoreSelfSaveCount == 2)
        #expect(store.lastErrorMessage == nil)
    }

    @Test("Archiving edits the latest row in place and leaves its listening alone")
    func archiveEditsTheLatestRowInPlace() async throws {
        let fixture = try await makeArchiveFixture()
        let store = fixture.store
        let episode = try fixture.episode("archive-1")
        #expect(store.updateProgress(
            episodeID: episode.episodeID,
            podcastID: episode.podcastID,
            position: 30,
            duration: 120,
            modelContext: fixture.context
        ))
        let record = try #require(store.progressRecord(for: episode.episodeID))
        record.updatedAt = Self.longAgo
        try fixture.context.save()
        let savesBeforeArchive = store.syncedStoreSelfSaveCount

        #expect(store.archive(episode, modelContext: fixture.context))

        #expect(try fixture.context.fetch(FetchDescriptor<EpisodeProgressRecord>()).count == 1)
        #expect(store.progressRecord(for: episode.episodeID) === record)
        #expect(record.position == 30)
        #expect(record.duration == 120)
        #expect(!record.isPlayed)
        #expect(record.archivedAt != nil)
        #expect(record.updatedAt > Self.longAgo)
        #expect(store.isArchived(episodeID: episode.episodeID))
        #expect(store.syncedStoreSelfSaveCount == savesBeforeArchive + 1)
    }

    /// The self-save ledger asserts in DEBUG that a credited save dirtied a
    /// synced row, so a no-op that saved would also stop the test there.
    @Test("An archive or unarchive that changes nothing does not save")
    func noOpArchiveWritesDoNotSave() async throws {
        let fixture = try await makeArchiveFixture()
        let store = fixture.store
        let unheard = try fixture.episode("archive-1")
        let heard = try fixture.episode("archive-2")

        #expect(!store.unarchive(unheard, modelContext: fixture.context))
        #expect(try fixture.context.fetch(FetchDescriptor<EpisodeProgressRecord>()).isEmpty)
        #expect(store.syncedStoreSelfSaveCount == 0)

        #expect(store.updateProgress(
            episodeID: heard.episodeID,
            podcastID: heard.podcastID,
            position: 30,
            duration: 120,
            modelContext: fixture.context
        ))
        #expect(!store.unarchive(heard, modelContext: fixture.context))
        #expect(store.syncedStoreSelfSaveCount == 1)

        #expect(store.archive(heard, modelContext: fixture.context))
        #expect(!store.archive(heard, modelContext: fixture.context))
        #expect(!store.archive([heard], modelContext: fixture.context))
        #expect(!store.archive([], modelContext: fixture.context))
        #expect(store.syncedStoreSelfSaveCount == 2)
        #expect(!fixture.context.hasChanges)
        #expect(store.archivedEpisodeIDs == [heard.episodeID])
        #expect(store.lastErrorMessage == nil)
    }

    @Test("Archiving several episodes of a show takes one save and leaves archived ones alone")
    func batchArchiveTakesOneSave() async throws {
        let fixture = try await makeArchiveFixture()
        let store = fixture.store
        let heard = try fixture.episode("archive-1")
        let unheard = try fixture.episode("archive-2")
        let archived = try fixture.episode("archive-3")
        #expect(store.updateProgress(
            episodeID: heard.episodeID,
            podcastID: heard.podcastID,
            position: 30,
            duration: 120,
            modelContext: fixture.context
        ))
        #expect(store.archive(archived, modelContext: fixture.context))
        let archivedRecord = try #require(store.progressRecord(for: archived.episodeID))
        archivedRecord.updatedAt = Self.longAgo
        archivedRecord.archivedAt = Self.longAgo
        try fixture.context.save()
        let savesBeforeBatch = store.syncedStoreSelfSaveCount

        #expect(store.archive([heard, unheard, archived], modelContext: fixture.context))

        #expect(store.syncedStoreSelfSaveCount == savesBeforeBatch + 1)
        #expect(store.archivedEpisodeIDs == [heard.episodeID, unheard.episodeID, archived.episodeID])
        #expect(try fixture.context.fetch(FetchDescriptor<EpisodeProgressRecord>()).count == 3)
        #expect(store.progressRecord(for: heard.episodeID)?.position == 30)
        #expect(archivedRecord.archivedAt == Self.longAgo)
        #expect(archivedRecord.updatedAt == Self.longAgo)
    }

    /// Unarchive All's write: the batch keeps each row and its listening and
    /// clears only the archive. A batch with nothing archived saves nothing
    /// (the DEBUG ledger assert would stop a no-op save here).
    @Test("Unarchiving several episodes of a show takes one save, leaves unarchived ones alone, and skips the save when none is archived")
    func batchUnarchiveTakesOneSave() async throws {
        let fixture = try await makeArchiveFixture()
        let store = fixture.store
        let heard = try fixture.episode("archive-1")
        let unheard = try fixture.episode("archive-2")
        let neverArchived = try fixture.episode("archive-3")
        #expect(store.updateProgress(
            episodeID: heard.episodeID,
            podcastID: heard.podcastID,
            position: 30,
            duration: 120,
            modelContext: fixture.context
        ))
        let neverArchivedRecord = insertProgress(
            neverArchived.episodeID,
            position: 10,
            updatedAt: Self.longAgo,
            into: fixture.context
        )
        try fixture.context.save()
        store.refreshProgressRecords(modelContext: fixture.context)
        #expect(!store.unarchive([heard, unheard, neverArchived], modelContext: fixture.context))
        #expect(!store.unarchive([], modelContext: fixture.context))
        #expect(store.archive([heard, unheard], modelContext: fixture.context))
        let savesBeforeBatch = store.syncedStoreSelfSaveCount

        #expect(store.unarchive([heard, unheard, neverArchived], modelContext: fixture.context))

        #expect(store.syncedStoreSelfSaveCount == savesBeforeBatch + 1)
        #expect(store.archivedEpisodeIDs.isEmpty)
        #expect(try fixture.context.fetch(FetchDescriptor<EpisodeProgressRecord>()).count == 3)
        #expect(store.progressRecord(for: heard.episodeID)?.position == 30)
        #expect(store.progressRecord(for: unheard.episodeID)?.archivedAt == nil)
        #expect(neverArchivedRecord.updatedAt == Self.longAgo)
        #expect(!store.unarchive([heard, unheard], modelContext: fixture.context))
        #expect(store.syncedStoreSelfSaveCount == savesBeforeBatch + 1)
        #expect(!fixture.context.hasChanges)
        #expect(store.lastErrorMessage == nil)
    }

    /// The batch unarchive shares the archive's undo: a failed save puts the
    /// archives back, so the context carries nothing out and a retry works.
    @Test("A failed batch unarchive is recorded and puts the archives back, and a retry unarchives")
    func failedBatchUnarchiveIsUndone() async throws {
        let saves = ArchiveSaveSwitch()
        let fixture = try await makeArchiveFixture(save: saves.save)
        let store = fixture.store
        let first = try fixture.episode("archive-1")
        let second = try fixture.episode("archive-2")
        #expect(store.archive([first, second], modelContext: fixture.context))
        let archivedAt = try #require(store.progressRecord(for: first.episodeID)?.archivedAt)
        let savesBeforeBatch = store.syncedStoreSelfSaveCount
        saves.fails = true

        #expect(!store.unarchive([first, second], modelContext: fixture.context))

        #expect(store.lastErrorMessage == ArchiveSaveFailure().errorDescription)
        #expect(store.archivedEpisodeIDs == [first.episodeID, second.episodeID])
        #expect(store.progressRecord(for: first.episodeID)?.archivedAt == archivedAt)
        #expect(store.syncedStoreSelfSaveCount == savesBeforeBatch)
        try fixture.context.save()
        let stored = try ModelContext(fixture.context.container).fetch(FetchDescriptor<EpisodeProgressRecord>())
        #expect(stored.count == 2)
        #expect(stored.allSatisfy { $0.archivedAt != nil })

        saves.fails = false
        #expect(store.unarchive([first, second], modelContext: fixture.context))
        #expect(store.archivedEpisodeIDs.isEmpty)
        #expect(store.syncedStoreSelfSaveCount == savesBeforeBatch + 1)
    }

    /// D3 and D8: listening and Mark Played edit the row in place and keep
    /// the archive; Clear Progress deletes the row and the archive with it.
    @Test("Listening and marking played keep the archive, and Clear Progress removes it")
    func listeningKeepsTheArchiveAndClearRemovesIt() async throws {
        let fixture = try await makeArchiveFixture()
        let store = fixture.store
        let first = try fixture.episode("archive-1")
        let second = try fixture.episode("archive-2")
        let both: Set = [first.episodeID, second.episodeID]
        #expect(store.archive([first, second], modelContext: fixture.context))
        #expect(store.archivedEpisodeIDs == both)

        #expect(store.updateProgress(
            episodeID: first.episodeID,
            podcastID: first.podcastID,
            position: 50,
            duration: 120,
            modelContext: fixture.context
        ))
        #expect(store.progressRecord(for: first.episodeID)?.position == 50)
        #expect(store.progressRecord(for: first.episodeID)?.archivedAt != nil)
        #expect(store.archivedEpisodeIDs == both)

        #expect(store.markEpisodePlayed(first, modelContext: fixture.context))
        #expect(store.progressRecord(for: first.episodeID)?.isPlayed == true)
        #expect(store.progressRecord(for: first.episodeID)?.archivedAt != nil)
        #expect(store.archivedEpisodeIDs == both)

        #expect(store.markAllPlayed(forPodcastID: Self.archiveFeedURL, modelContext: fixture.context))
        #expect(store.progressRecord(for: second.episodeID)?.isPlayed == true)
        #expect(store.progressRecord(for: second.episodeID)?.archivedAt != nil)
        #expect(store.progressRecord(for: "archive-3")?.isPlayed == true)
        #expect(store.progressRecord(for: "archive-3")?.archivedAt == nil)
        #expect(store.archivedEpisodeIDs == both)

        #expect(store.clearProgress(for: first, modelContext: fixture.context))
        #expect(store.progressRecord(for: first.episodeID) == nil)
        #expect(store.archivedEpisodeIDs == [second.episodeID])
        #expect(store.lastErrorMessage == nil)
    }

    @Test("A failed archive save is recorded and leaves the episode in the Inbox")
    func failedArchiveSaveIsRecorded() async throws {
        let saves = ArchiveSaveSwitch()
        let fixture = try await makeArchiveFixture(save: saves.save)
        let store = fixture.store
        let episode = try fixture.episode("archive-1")
        saves.fails = true

        #expect(!store.archive(episode, modelContext: fixture.context))

        #expect(store.lastErrorMessage == ArchiveSaveFailure().errorDescription)
        #expect(store.state == .failed(ArchiveSaveFailure().errorDescription ?? ""))
        #expect(!store.isArchived(episodeID: episode.episodeID))
        #expect(store.syncedStoreSelfSaveCount == 0)
    }

    /// The context is shared with other writers. A failed archive that left
    /// its rows dirty would turn the retry into a no-op, and the next
    /// unrelated save of the context (Up Next saves it directly) would carry
    /// the archive out with no self-save credit.
    @Test("A failed archive puts its rows back, so a later save carries nothing and a retry archives")
    func failedArchiveLeavesNothingPending() async throws {
        let saves = ArchiveSaveSwitch()
        let fixture = try await makeArchiveFixture(save: saves.save)
        let store = fixture.store
        let heard = try fixture.episode("archive-1")
        let unheard = try fixture.episode("archive-2")
        let heardRecord = insertProgress(heard.episodeID, position: 30, updatedAt: Self.longAgo, into: fixture.context)
        try fixture.context.save()
        store.refreshProgressRecords(modelContext: fixture.context)
        saves.fails = true

        #expect(!store.archive([heard, unheard], modelContext: fixture.context))

        #expect(heardRecord.archivedAt == nil)
        #expect(heardRecord.updatedAt == Self.longAgo)
        #expect(try fixture.context.fetch(FetchDescriptor<EpisodeProgressRecord>()).map(\.episodeID) == [heard.episodeID])
        #expect(store.archivedEpisodeIDs.isEmpty)
        #expect(store.syncedStoreSelfSaveCount == 0)

        try fixture.context.save()
        let storedAfterUnrelatedSave = try ModelContext(fixture.context.container)
            .fetch(FetchDescriptor<EpisodeProgressRecord>())
        #expect(storedAfterUnrelatedSave.count == 1)
        #expect(storedAfterUnrelatedSave.first?.archivedAt == nil)
        #expect(storedAfterUnrelatedSave.first?.updatedAt == Self.longAgo)

        saves.fails = false
        #expect(store.archive([heard, unheard], modelContext: fixture.context))

        #expect(store.syncedStoreSelfSaveCount == 1)
        #expect(heardRecord.archivedAt != nil)
        #expect(store.archivedEpisodeIDs == [heard.episodeID, unheard.episodeID])
        let storedAfterRetry = try ModelContext(fixture.context.container)
            .fetch(FetchDescriptor<EpisodeProgressRecord>())
        #expect(storedAfterRetry.count == 2)
        #expect(storedAfterRetry.allSatisfy { $0.archivedAt != nil })
    }

    /// An episode ID already names its show, and the archived set is keyed
    /// by it, so a write finds the episode's row whatever feed spelling it
    /// was stored under.
    @Test("Unarchive finds a lone archived row stored under a feed-URL variant")
    func unarchiveFindsAVariantRow() async throws {
        let fixture = try await makeArchiveFixture()
        let store = fixture.store
        let episode = try fixture.episode("archive-1")
        let variantRecord = insertProgress(
            episode.episodeID,
            podcastID: Self.variantFeedURL,
            archivedAt: Self.longAgo,
            updatedAt: Self.longAgo,
            into: fixture.context
        )
        try fixture.context.save()
        store.refreshProgressRecords(modelContext: fixture.context)
        #expect(store.isArchived(episodeID: episode.episodeID))

        #expect(store.unarchive(episode, modelContext: fixture.context))

        #expect(variantRecord.archivedAt == nil)
        #expect(variantRecord.updatedAt > Self.longAgo)
        #expect(variantRecord.podcastID == Self.variantFeedURL)
        #expect(try fixture.context.fetch(FetchDescriptor<EpisodeProgressRecord>()).count == 1)
        #expect(store.archivedEpisodeIDs.isEmpty)
        #expect(store.syncedStoreSelfSaveCount == 1)
    }

    /// The index takes an episode's newest copy as its latest row, so the
    /// archive has to land on that copy whichever feed spelling holds it.
    /// Positions run against the timestamps, so a pick by position fails.
    @Test("Archiving edits the newest of an episode's competing copies, whatever feed spelling holds it")
    func archiveEditsTheNewestOfCompetingCopies() async throws {
        let fixture = try await makeArchiveFixture()
        let store = fixture.store
        let first = try fixture.episode("archive-1")
        let second = try fixture.episode("archive-2")
        let newer = Self.longAgo.addingTimeInterval(100)
        let firstOlder = insertProgress(first.episodeID, position: 90, updatedAt: Self.longAgo, into: fixture.context)
        let firstNewer = insertProgress(
            first.episodeID,
            podcastID: Self.variantFeedURL,
            position: 10,
            updatedAt: newer,
            into: fixture.context
        )
        let secondOlder = insertProgress(
            second.episodeID,
            podcastID: Self.variantFeedURL,
            position: 90,
            updatedAt: Self.longAgo,
            into: fixture.context
        )
        let secondNewer = insertProgress(second.episodeID, position: 10, updatedAt: newer, into: fixture.context)
        try fixture.context.save()
        store.refreshProgressRecords(modelContext: fixture.context)

        #expect(store.archive([first, second], modelContext: fixture.context))

        #expect(store.syncedStoreSelfSaveCount == 1)
        for record in [firstNewer, secondNewer] {
            #expect(record.archivedAt != nil)
            #expect(record.updatedAt > newer)
        }
        for record in [firstOlder, secondOlder] {
            #expect(record.archivedAt == nil)
            #expect(record.updatedAt == Self.longAgo)
        }
        #expect(store.progressRecord(for: first.episodeID) === firstNewer)
        #expect(store.progressRecord(for: second.episodeID) === secondNewer)
        #expect(store.archivedEpisodeIDs == [first.episodeID, second.episodeID])

        store.refreshProgressRecords(modelContext: fixture.context)
        #expect(store.archivedEpisodeIDs == [first.episodeID, second.episodeID])
    }

    /// The episode tombstone Clear Progress writes shadows by episode ID, so
    /// every copy goes: an older copy left under a feed-URL variant would
    /// become the latest row and bring its archive back until repair ran.
    @Test("Clear Progress deletes every copy of the episode, so an older variant copy cannot re-archive it")
    func clearDeletesEveryCopyOfTheEpisode() async throws {
        let fixture = try await makeArchiveFixture()
        let store = fixture.store
        let episode = try fixture.episode("archive-1")
        insertProgress(
            episode.episodeID,
            podcastID: Self.variantFeedURL,
            archivedAt: Self.longAgo,
            updatedAt: Self.longAgo,
            into: fixture.context
        )
        insertProgress(
            episode.episodeID,
            position: 30,
            updatedAt: Self.longAgo.addingTimeInterval(100),
            into: fixture.context
        )
        try fixture.context.save()
        store.refreshProgressRecords(modelContext: fixture.context)
        #expect(!store.isArchived(episodeID: episode.episodeID))

        #expect(store.clearProgress(for: episode, modelContext: fixture.context))
        store.refreshProgressRecords(modelContext: fixture.context)

        #expect(try fixture.context.fetch(FetchDescriptor<EpisodeProgressRecord>()).isEmpty)
        #expect(store.progressRecord(for: episode.episodeID) == nil)
        #expect(store.archivedEpisodeIDs.isEmpty)
        let tombstones = try fixture.context.fetch(FetchDescriptor<SyncTombstoneRecord>())
        #expect(tombstones.map(\.episodeID) == [episode.episodeID])
    }

    /// An import edits the live rows before the projection reloads them. A
    /// batch that finds a row already archived writes nothing for it, but
    /// the set still takes it in; with nothing to write at all, the set
    /// takes it in without a save.
    @Test("A batch archive brings imported archives into the set, with or without a save")
    func batchArchiveReconcilesRowsItDidNotChange() async throws {
        let fixture = try await makeArchiveFixture()
        let store = fixture.store
        let first = try fixture.episode("archive-1")
        let second = try fixture.episode("archive-2")
        let third = try fixture.episode("archive-3")
        for episode in [first, second] {
            #expect(store.updateProgress(
                episodeID: episode.episodeID,
                podcastID: episode.podcastID,
                position: 30,
                duration: 120,
                modelContext: fixture.context
            ))
        }
        let savesBeforeArchive = store.syncedStoreSelfSaveCount
        let importContext = ModelContext(fixture.context.container)
        let importedSecond = try #require(
            importContext.fetch(FetchDescriptor<EpisodeProgressRecord>())
                .first { $0.episodeID == second.episodeID }
        )
        importedSecond.archivedAt = .now
        importedSecond.updatedAt = .now
        importContext.insert(
            EpisodeProgressRecord(
                episodeID: third.episodeID,
                podcastID: third.podcastID,
                archivedAt: .now,
                updatedAt: .now
            )
        )
        try importContext.save()
        #expect(store.archivedEpisodeIDs.isEmpty)

        #expect(store.archive([first, second], modelContext: fixture.context))
        #expect(store.syncedStoreSelfSaveCount == savesBeforeArchive + 1)
        #expect(store.archivedEpisodeIDs == [first.episodeID, second.episodeID])

        #expect(!store.archive([third], modelContext: fixture.context))
        #expect(store.syncedStoreSelfSaveCount == savesBeforeArchive + 1)
        #expect(store.archivedEpisodeIDs == [first.episodeID, second.episodeID, third.episodeID])
    }

    /// A progress write lands on the row under the feed spelling it was
    /// given. Beside an older archived copy under another spelling it
    /// inserts a new row, which becomes the episode's latest, and the
    /// archive drops out (R2). Nothing reloads, so the write itself has to
    /// move the set.
    @Test("A progress write beside an archived variant copy becomes the latest row and moves the set")
    func progressWriteBesideAnArchivedVariantCopyMovesTheSet() async throws {
        let fixture = try await makeArchiveFixture()
        let store = fixture.store
        let episode = try fixture.episode("archive-1")
        insertProgress(
            episode.episodeID,
            podcastID: Self.variantFeedURL,
            archivedAt: Self.longAgo,
            updatedAt: Self.longAgo,
            into: fixture.context
        )
        try fixture.context.save()
        store.refreshProgressRecords(modelContext: fixture.context)
        #expect(store.isArchived(episodeID: episode.episodeID))

        #expect(store.updateProgress(
            episodeID: episode.episodeID,
            podcastID: episode.podcastID,
            position: 30,
            duration: 120,
            modelContext: fixture.context
        ))

        #expect(try fixture.context.fetch(FetchDescriptor<EpisodeProgressRecord>()).count == 2)
        #expect(store.progressRecord(for: episode.episodeID)?.podcastID == Self.archiveFeedURL)
        #expect(store.archivedEpisodeIDs.isEmpty)

        store.refreshProgressRecords(modelContext: fixture.context)
        #expect(store.archivedEpisodeIDs.isEmpty)
    }

    /// Another device archives the older of an episode's two copies, which
    /// makes it the latest. The synced reload finds the same live rows in
    /// the same order (the canonical copy sorts first whatever the stamps),
    /// so they compare unchanged; the store still has to follow that copy,
    /// or the archive and the listening describe different copies.
    @Test("A synced reload follows the copy an import made latest: progress, played state and the archive agree")
    func syncedReloadFollowsTheCopyAnImportMadeLatest() async throws {
        let fixture = try await makeArchiveFixture()
        let store = fixture.store
        let episode = try fixture.episode("archive-1")
        let (older, newer) = insertCompetingCopies(of: episode.episodeID, into: fixture.context)
        try fixture.context.save()
        store.refreshProgressRecords(modelContext: fixture.context)
        #expect(store.progressRecord(for: episode.episodeID) === newer)
        #expect(!store.progressSummary(for: episode).isCompleted)

        try archiveCanonicalCopyInAnotherContext(of: episode.episodeID, container: fixture.context.container)
        let result = try store.reloadSyncedUserData(modelContext: fixture.context)

        #expect(result.progressRecordsChanged)
        #expect(store.progressRecord(for: episode.episodeID) === older)
        #expect(store.isArchived(episodeID: episode.episodeID))
        #expect(store.progressSummary(for: episode).isCompleted)
    }

    /// The same import, met by Archive before any reload: nothing is written
    /// for that episode, alone or in a batch that saves for another, and the
    /// store still follows the copy that is now latest.
    @Test("An archive that finds the copy an import made latest follows it, with or without a save")
    func archiveFollowsTheCopyAnImportMadeLatest() async throws {
        let fixture = try await makeArchiveFixture()
        let store = fixture.store
        let alone = try fixture.episode("archive-1")
        let inBatch = try fixture.episode("archive-2")
        let unheard = try fixture.episode("archive-3")
        let (aloneOlder, aloneNewer) = insertCompetingCopies(of: alone.episodeID, into: fixture.context)
        let (batchOlder, batchNewer) = insertCompetingCopies(of: inBatch.episodeID, into: fixture.context)
        try fixture.context.save()
        store.refreshProgressRecords(modelContext: fixture.context)
        #expect(store.progressRecord(for: alone.episodeID) === aloneNewer)
        #expect(store.progressRecord(for: inBatch.episodeID) === batchNewer)
        for episode in [alone, inBatch] {
            try archiveCanonicalCopyInAnotherContext(of: episode.episodeID, container: fixture.context.container)
        }

        #expect(!store.archive(alone, modelContext: fixture.context))
        #expect(store.syncedStoreSelfSaveCount == 0)
        #expect(store.progressRecord(for: alone.episodeID) === aloneOlder)
        #expect(store.isArchived(episodeID: alone.episodeID))
        #expect(store.progressSummary(for: alone).isCompleted)

        #expect(store.archive([inBatch, unheard], modelContext: fixture.context))
        #expect(store.syncedStoreSelfSaveCount == 1)
        #expect(store.progressRecord(for: inBatch.episodeID) === batchOlder)
        #expect(store.isArchived(episodeID: inBatch.episodeID))
        #expect(store.progressSummary(for: inBatch).isCompleted)
        #expect(store.isArchived(episodeID: unheard.episodeID))
    }

    /// Two copies of one episode, unsaved: an older finished copy under the
    /// canonical feed URL and a newer in-progress copy under the variant
    /// spelling, which sorts after the canonical one.
    private func insertCompetingCopies(
        of episodeID: String,
        into context: ModelContext
    ) -> (older: EpisodeProgressRecord, newer: EpisodeProgressRecord) {
        let older = insertProgress(episodeID, position: 120, isPlayed: true, updatedAt: Self.longAgo, into: context)
        let newer = insertProgress(
            episodeID,
            podcastID: Self.variantFeedURL,
            position: 30,
            updatedAt: Self.longAgo.addingTimeInterval(100),
            into: context
        )
        return (older, newer)
    }

    /// Archives the episode's canonical copy from a second context, stamped
    /// newer than any fixture row, as a sync import does.
    private func archiveCanonicalCopyInAnotherContext(of episodeID: String, container: ModelContainer) throws {
        let importContext = ModelContext(container)
        let record = try #require(
            importContext.fetch(FetchDescriptor<EpisodeProgressRecord>())
                .first { $0.episodeID == episodeID && $0.podcastID == Self.archiveFeedURL }
        )
        record.archivedAt = Self.longAgo.addingTimeInterval(200)
        record.updatedAt = Self.longAgo.addingTimeInterval(200)
        try importContext.save()
    }

    /// One progress row with a two-minute duration, saved by the caller.
    @discardableResult
    private func insertProgress(
        _ episodeID: String,
        podcastID: String = LibraryProgressWriteTests.archiveFeedURL,
        position: Double = 0,
        isPlayed: Bool = false,
        archivedAt: Date? = nil,
        updatedAt: Date,
        into context: ModelContext
    ) -> EpisodeProgressRecord {
        let record = EpisodeProgressRecord(
            episodeID: episodeID,
            podcastID: podcastID,
            position: position,
            duration: 120,
            isPlayed: isPlayed,
            archivedAt: archivedAt,
            updatedAt: updatedAt
        )
        context.insert(record)
        return record
    }

    @MainActor
    private struct ArchiveFixture {
        let context: ModelContext
        let store: LibraryStore

        func episode(_ episodeID: String) throws -> EpisodeListItemSnapshot {
            try #require(store.episode(with: episodeID))
        }
    }

    /// One followed show with three cached episodes, archive-1 newest.
    private func makeArchiveFixture(
        save: @escaping (ModelContext) throws -> Void = { try $0.save() }
    ) async throws -> ArchiveFixture {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let cache = SQLiteLocalLibraryCacheStore.inMemory()
        let podcast = Podcast(
            id: PodcastID(rawValue: Self.archiveFeedURL),
            feedURL: try #require(URL(string: Self.archiveFeedURL)),
            title: "Archive Show"
        )
        let episodes = (1...3).map { index in
            Episode(
                id: EpisodeID(rawValue: "archive-\(index)"),
                podcastID: podcast.id,
                podcastTitle: podcast.title,
                title: "Episode \(index)",
                publishedAt: Date(timeIntervalSince1970: 2_000_000 - Double(index)),
                duration: 120,
                audioURL: URL(string: "https://example.com/archive-\(index).mp3"),
                guid: "archive-\(index)"
            )
        }
        try await cache.upsertCache(from: FeedSnapshot(podcast: podcast, episodes: episodes), refreshedAt: .now)
        context.insert(SubscriptionRecord(feedURL: Self.archiveFeedURL, title: podcast.title))
        try context.save()
        let store = LibraryStore(localCache: cache, savePlaybackSkipSettingsModelContext: save)
        #expect(await store.load(modelContext: context))
        return ArchiveFixture(context: context, store: store)
    }
}

private final class ArchiveSaveSwitch {
    var fails = false

    func save(_ context: ModelContext) throws {
        if fails {
            throw ArchiveSaveFailure()
        }
        try context.save()
    }
}

private struct ArchiveSaveFailure: LocalizedError {
    var errorDescription: String? {
        "Simulated archive save failure"
    }
}
