import Foundation
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Episode progress writer status revision")
struct EpisodeProgressWriterTests {
    private let episodeID = "status-episode"
    private let podcastID = "https://example.com/status.xml"
    private let duration: TimeInterval = 600

    /// A boundary flush with Now Playing presented saves with the observable
    /// refresh suppressed. The status change it carries has to outlive the
    /// suppression: the next observable write compares against the
    /// already-updated row and cannot see the change on its own.
    @Test("A suppressed status change publishes with the next observable write")
    func suppressedStatusChangePublishesWithNextObservableWrite() throws {
        let (writer, context) = try makeWriter()
        try save(writer, position: 0, modelContext: context, refreshObservableProgress: true)
        let published = writer.statusRevision

        try save(writer, position: 10, modelContext: context, refreshObservableProgress: false)
        #expect(writer.statusRevision == published)

        try save(writer, position: 20, modelContext: context, refreshObservableProgress: true)
        #expect(writer.statusRevision != published)
    }

    @Test("A suppressed status change publishes on the next refetch")
    func suppressedStatusChangePublishesOnRefetch() throws {
        let (writer, context) = try makeWriter()
        try save(writer, position: 300, modelContext: context, refreshObservableProgress: true)
        let published = writer.statusRevision

        try save(writer, position: duration, modelContext: context, refreshObservableProgress: false)
        #expect(writer.statusRevision == published)
        #expect(writer.latestRecord(for: episodeID)?.isPlayed == true)

        // The projection already holds the mutated row, so the refetch has
        // nothing to replace; the pending change still publishes.
        #expect(try writer.reloadIfChanged(modelContext: context) == false)
        #expect(writer.statusRevision != published)
    }

    @Test("A suppressed position-only write leaves nothing pending")
    func suppressedPositionOnlyWriteLeavesNothingPending() throws {
        let (writer, context) = try makeWriter()
        try save(writer, position: 10, modelContext: context, refreshObservableProgress: true)
        let published = writer.statusRevision

        try save(writer, position: 20, modelContext: context, refreshObservableProgress: false)
        try save(writer, position: 30, modelContext: context, refreshObservableProgress: true)
        #expect(writer.statusRevision == published)

        try writer.reloadIfChanged(modelContext: context)
        #expect(writer.statusRevision == published)
    }

    /// Archiving is not a listen: an in-place archive leaves both revisions
    /// alone and publishes through the archived set. Only a new row, from
    /// archiving an episode with none, changes the index and its revision.
    @Test("An archive moves the archived set and only a new row moves the revision")
    func archiveMovesTheArchivedSetNotTheRevisions() throws {
        let (writer, context) = try makeWriter()
        try save(writer, position: 30, modelContext: context, refreshObservableProgress: true)
        let record = try #require(writer.latestRecord(for: episodeID))
        let revision = writer.revision
        let statusRevision = writer.statusRevision

        #expect(try writer.setArchived(true, episodeID: episodeID, podcastID: podcastID, modelContext: context))
        #expect(writer.archivedEpisodeIDs == [episodeID])
        #expect(writer.latestRecord(for: episodeID) === record)
        #expect(record.archivedAt != nil)
        #expect(record.position == 30)
        #expect(writer.revision == revision)
        #expect(writer.statusRevision == statusRevision)

        #expect(try writer.setArchived(true, episodeID: "unheard", podcastID: podcastID, modelContext: context))
        #expect(writer.archivedEpisodeIDs == [episodeID, "unheard"])
        #expect(writer.latestRecord(for: "unheard")?.position == 0)
        #expect(writer.revision != revision)
        #expect(writer.statusRevision == statusRevision)

        #expect(try writer.setArchived(false, episodeID: episodeID, podcastID: podcastID, modelContext: context))
        #expect(writer.archivedEpisodeIDs == ["unheard"])
        #expect(record.archivedAt == nil)
    }

    /// A refetch that imports another context's edit finds the same live
    /// objects it already indexes, so the rows compare unchanged; the
    /// archived set has to be rebuilt anyway.
    @Test("A refetch rebuilds the archived set even when the rows compare unchanged")
    func refetchRebuildsArchivedSetWhenRowsCompareUnchanged() throws {
        let (writer, context) = try makeWriter()
        try save(writer, position: 30, modelContext: context, refreshObservableProgress: true)
        let record = try #require(writer.latestRecord(for: episodeID))

        record.archivedAt = .now
        try context.save()
        #expect(writer.archivedEpisodeIDs.isEmpty)
        #expect(try writer.reloadIfChanged(modelContext: context) == false)
        #expect(writer.archivedEpisodeIDs == [episodeID])

        record.archivedAt = nil
        try context.save()
        #expect(try writer.reloadIfChanged(modelContext: context) == false)
        #expect(writer.archivedEpisodeIDs.isEmpty)

        record.archivedAt = .now
        try context.save()
        try writer.reload(modelContext: context)
        #expect(writer.archivedEpisodeIDs == [episodeID])

        writer.reset()
        #expect(writer.archivedEpisodeIDs.isEmpty)
    }

    /// The set is the membership signal: a reader of it alone invalidates
    /// on an archive, and a rebuild that finds the same set stays quiet.
    @Test("Archived set readers invalidate on a change and not on an equal rebuild")
    func archivedSetReadersInvalidateOnlyOnChange() async throws {
        let (writer, context) = try makeWriter()
        try save(writer, position: 30, modelContext: context, refreshObservableProgress: true)

        await confirmation("an archive invalidates a reader of the set") { invalidated in
            withObservationTracking {
                _ = writer.archivedEpisodeIDs
            } onChange: {
                invalidated()
            }
            _ = try? writer.setArchived(true, episodeID: episodeID, podcastID: podcastID, modelContext: context)
        }

        await confirmation("an equal rebuild leaves a reader of the set alone", expectedCount: 0) { invalidated in
            withObservationTracking {
                _ = writer.archivedEpisodeIDs
            } onChange: {
                invalidated()
            }
            try? writer.reload(modelContext: context)
            _ = try? writer.reloadIfChanged(modelContext: context)
        }
        #expect(writer.archivedEpisodeIDs == [episodeID])
    }

    /// Another device archives the older of two copies, which makes it the
    /// latest. The canonical copy sorts before the variant whatever their
    /// stamps, so the refetch finds the same live rows in the same order and
    /// they compare unchanged; the index has to move to that copy anyway, or
    /// the archive and the listening describe different copies.
    @Test("A refetch indexes the copy an import made latest, even when the rows compare unchanged")
    func refetchIndexesTheCopyAnImportMadeLatest() throws {
        let (writer, context) = try makeWriter()
        let (older, newer) = insertCompetingCopies(into: context)
        try context.save()
        try writer.reload(modelContext: context)
        #expect(writer.latestRecord(for: episodeID) === newer)
        let revision = writer.revision

        try archiveInAnotherContext(episodeID: episodeID, podcastID: podcastID, container: context.container)

        #expect(try writer.reloadIfChanged(modelContext: context))
        #expect(writer.latestRecord(for: episodeID) === older)
        #expect(writer.latestRecord(for: episodeID)?.isPlayed == true)
        #expect(writer.archivedEpisodeIDs == [episodeID])
        #expect(writer.revision != revision)

        let settledRevision = writer.revision
        #expect(try writer.reloadIfChanged(modelContext: context) == false)
        #expect(writer.revision == settledRevision)
    }

    /// The same import, met by an archive request before any reload: the
    /// request writes nothing for that episode, alone or in a batch that
    /// saves for another, and still indexes the copy that is now latest.
    @Test("An archive request indexes the copy an import made latest, with or without a save")
    func archiveRequestIndexesTheCopyAnImportMadeLatest() throws {
        let (writer, context) = try makeWriter()
        let batchEpisodeID = "batch-episode"
        let (older, _) = insertCompetingCopies(into: context)
        let (batchOlder, batchNewer) = insertCompetingCopies(of: batchEpisodeID, into: context)
        try context.save()
        try writer.reload(modelContext: context)
        #expect(writer.latestRecord(for: batchEpisodeID) === batchNewer)
        try archiveInAnotherContext(episodeID: episodeID, podcastID: podcastID, container: context.container)
        try archiveInAnotherContext(episodeID: batchEpisodeID, podcastID: podcastID, container: context.container)
        let revision = writer.revision

        #expect(try writer.setArchived(true, episodeID: episodeID, podcastID: podcastID, modelContext: context) == false)
        #expect(!context.hasChanges)
        #expect(writer.latestRecord(for: episodeID) === older)
        #expect(writer.archivedEpisodeIDs == [episodeID])
        #expect(writer.revision != revision)

        let batchRevision = writer.revision
        #expect(try writer.setArchived(
            true,
            episodeIDs: [batchEpisodeID, "unheard"],
            podcastID: podcastID,
            modelContext: context
        ))
        #expect(writer.latestRecord(for: batchEpisodeID) === batchOlder)
        #expect(writer.latestRecord(for: batchEpisodeID)?.isPlayed == true)
        #expect(writer.archivedEpisodeIDs == [episodeID, batchEpisodeID, "unheard"])
        #expect(writer.revision != batchRevision)
    }

    private func makeWriter() throws -> (EpisodeProgressWriter, ModelContext) {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let writer = EpisodeProgressWriter(ledger: SyncedStoreSelfSaveLedger())
        try writer.reload(modelContext: context)
        return (writer, context)
    }

    /// Two copies of one episode, unsaved: an older finished copy under the
    /// canonical feed URL and a newer in-progress copy under a variant
    /// spelling of it, which sorts after the canonical one.
    private func insertCompetingCopies(
        of episodeID: String? = nil,
        into context: ModelContext
    ) -> (older: EpisodeProgressRecord, newer: EpisodeProgressRecord) {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let older = EpisodeProgressRecord(
            episodeID: episodeID ?? self.episodeID,
            podcastID: podcastID,
            position: duration,
            duration: duration,
            isPlayed: true,
            updatedAt: stamp
        )
        let newer = EpisodeProgressRecord(
            episodeID: episodeID ?? self.episodeID,
            podcastID: podcastID + "/",
            position: 30,
            duration: duration,
            updatedAt: stamp.addingTimeInterval(100)
        )
        context.insert(older)
        context.insert(newer)
        return (older, newer)
    }

    /// Archives the episode's copy stored under `podcastID` from a second
    /// context, stamped newer than any fixture row, as a sync import does.
    private func archiveInAnotherContext(
        episodeID: String,
        podcastID: String,
        container: ModelContainer
    ) throws {
        let importContext = ModelContext(container)
        let record = try #require(
            importContext.fetch(FetchDescriptor<EpisodeProgressRecord>())
                .first { $0.episodeID == episodeID && $0.podcastID == podcastID }
        )
        let stamp = Date(timeIntervalSince1970: 1_700_000_000).addingTimeInterval(200)
        record.archivedAt = stamp
        record.updatedAt = stamp
        try importContext.save()
    }

    private func save(
        _ writer: EpisodeProgressWriter,
        position: TimeInterval,
        modelContext: ModelContext,
        refreshObservableProgress: Bool
    ) throws {
        #expect(try writer.update(
            episodeID: episodeID,
            podcastID: podcastID,
            position: position,
            duration: duration,
            isPlayed: EpisodeProgressRules.isPlayed(position: position, duration: duration),
            modelContext: modelContext,
            refreshObservableProgress: refreshObservableProgress
        ))
    }
}
