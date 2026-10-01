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

    private func makeWriter() throws -> (EpisodeProgressWriter, ModelContext) {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let writer = EpisodeProgressWriter(ledger: SyncedStoreSelfSaveLedger())
        try writer.reload(modelContext: context)
        return (writer, context)
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
