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
}
