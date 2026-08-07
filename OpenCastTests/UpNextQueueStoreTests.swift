import Foundation
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Up Next queue store")
struct UpNextQueueStoreTests {
    @Test("Play Next fronts the queue and Play Last preserves FIFO order")
    func frontAndBackOrdering() throws {
        let fixture = try makeFixture()
        let first = episode("first")
        let second = episode("second")
        let next = episode("next")

        #expect(fixture.store.enqueueLast(first, modelContext: fixture.context))
        #expect(fixture.store.enqueueLast(second, modelContext: fixture.context))
        #expect(fixture.store.enqueueNext(next, modelContext: fixture.context))

        #expect(fixture.store.items.map(\.episodeID) == ["next", "first", "second"])
        #expect(popEpisodeID(from: fixture.store, modelContext: fixture.context) == "next")
        #expect(popEpisodeID(from: fixture.store, modelContext: fixture.context) == "first")
        #expect(popEpisodeID(from: fixture.store, modelContext: fixture.context) == "second")
        #expect(popEpisodeID(from: fixture.store, modelContext: fixture.context) == nil)
    }

    @Test("Re-enqueueing moves an item instead of duplicating it")
    func dedupeMoves() throws {
        let fixture = try makeFixture()
        #expect(fixture.store.enqueueLast(episode("first"), modelContext: fixture.context))
        #expect(fixture.store.enqueueLast(episode("second"), modelContext: fixture.context))

        #expect(fixture.store.enqueueNext(episode("second"), modelContext: fixture.context))

        #expect(fixture.store.items.map(\.episodeID) == ["second", "first"])
        #expect(try fixture.context.fetch(FetchDescriptor<UpNextQueueItemRecord>()).count == 2)
    }

    @Test("Reordering is persisted across a fresh store load")
    func reorderPersists() throws {
        let fixture = try makeFixture()
        for id in ["first", "second", "third"] {
            #expect(fixture.store.enqueueLast(episode(id), modelContext: fixture.context))
        }
        #expect(
            fixture.store.reorderVisibleEpisodeIDs(
                ["second", "third", "first"],
                modelContext: fixture.context
            )
        )
        let reloaded = UpNextQueueStore()
        let freshContext = ModelContext(fixture.container)

        reloaded.load(
            resolveEpisode: { self.episode($0) },
            mayPruneUnresolved: true,
            modelContext: freshContext
        )

        #expect(reloaded.items.map(\.episodeID) == ["second", "third", "first"])
        #expect(reloaded.items.map(\.sequence) == [0, 1, 2])
    }

    @Test("Popping the head deletes its persisted record")
    func popDeletesRecord() throws {
        let fixture = try makeFixture()
        #expect(fixture.store.enqueueLast(episode("first"), modelContext: fixture.context))
        #expect(fixture.store.enqueueLast(episode("second"), modelContext: fixture.context))

        #expect(popEpisodeID(from: fixture.store, modelContext: fixture.context) == "first")

        let records = try fixture.context.fetch(FetchDescriptor<UpNextQueueItemRecord>())
        #expect(records.map(\.episodeID) == ["second"])
    }

    @Test("Clear removes every queue item")
    func clear() throws {
        let fixture = try makeFixture()
        #expect(fixture.store.enqueueLast(episode("first"), modelContext: fixture.context))
        #expect(fixture.store.enqueueLast(episode("second"), modelContext: fixture.context))

        #expect(fixture.store.clear(modelContext: fixture.context))

        #expect(fixture.store.items.isEmpty)
        #expect(try fixture.context.fetch(FetchDescriptor<UpNextQueueItemRecord>()).isEmpty)
    }

    @Test("Removing a podcast keeps other shows queued")
    func removePodcast() throws {
        let fixture = try makeFixture()
        #expect(
            fixture.store.enqueueLast(
                episode("removed", podcastID: "removed-show"),
                modelContext: fixture.context
            )
        )
        #expect(
            fixture.store.enqueueLast(
                episode("kept", podcastID: "kept-show"),
                modelContext: fixture.context
            )
        )

        #expect(fixture.store.removeAll(forPodcastID: "removed-show", modelContext: fixture.context))

        #expect(fixture.store.items.map(\.episodeID) == ["kept"])
        #expect(try fixture.context.fetch(FetchDescriptor<UpNextQueueItemRecord>()).map(\.episodeID) == ["kept"])
    }

    @Test("Load drops records whose episode can no longer be resolved")
    func loadDropsUnresolvableRecords() throws {
        let fixture = try makeFixture()
        fixture.context.insert(
            UpNextQueueItemRecord(
                episodeID: "missing",
                podcastID: "show",
                sequence: 0
            )
        )
        fixture.context.insert(
            UpNextQueueItemRecord(
                episodeID: "kept",
                podcastID: "show",
                sequence: 1
            )
        )
        try fixture.context.save()

        fixture.store.load(
            resolveEpisode: { $0 == "kept" ? self.episode($0) : nil },
            mayPruneUnresolved: true,
            modelContext: fixture.context
        )

        #expect(fixture.store.items.map(\.episodeID) == ["kept"])
        let records = try fixture.context.fetch(FetchDescriptor<UpNextQueueItemRecord>())
        #expect(records.map(\.episodeID) == ["kept"])
        #expect(records.map(\.sequence) == [0])
    }

    @Test("A failed library load preserves every queued ID until a later authoritative prune")
    func failedLibraryLoadPreservesThenSuccessfulLoadPrunes() throws {
        let fixture = try makeFixture()
        for (sequence, episodeID) in ["missing", "kept"].enumerated() {
            fixture.context.insert(
                UpNextQueueItemRecord(
                    episodeID: episodeID,
                    podcastID: "show",
                    sequence: sequence
                )
            )
        }
        try fixture.context.save()

        fixture.store.load(
            resolveEpisode: { _ in nil },
            mayPruneUnresolved: false,
            modelContext: fixture.context
        )

        #expect(fixture.store.items.map(\.episodeID) == ["missing", "kept"])
        let preservedContext = ModelContext(fixture.container)
        #expect(
            try preservedContext.fetch(FetchDescriptor<UpNextQueueItemRecord>())
                .sorted { $0.sequence < $1.sequence }
                .map(\.episodeID) == ["missing", "kept"]
        )

        let authoritativeContext = ModelContext(fixture.container)
        fixture.store.load(
            resolveEpisode: { $0 == "kept" ? self.episode($0) : nil },
            mayPruneUnresolved: true,
            modelContext: authoritativeContext
        )

        #expect(fixture.store.items.map(\.episodeID) == ["kept"])
        let reloadedContext = ModelContext(fixture.container)
        let records = try reloadedContext.fetch(FetchDescriptor<UpNextQueueItemRecord>())
        #expect(records.map(\.episodeID) == ["kept"])
        #expect(records.map(\.sequence) == [0])
    }

    @Test("An authoritative empty library prunes every stale queue record")
    func authoritativeEmptyLibraryPrunesAllRecords() throws {
        let fixture = try loadedFixture(ids: ["first", "second"])
        let freshContext = ModelContext(fixture.container)

        fixture.store.load(
            resolveEpisode: { _ in nil },
            mayPruneUnresolved: true,
            modelContext: freshContext
        )

        #expect(fixture.store.items.isEmpty)
        let reloadedContext = ModelContext(fixture.container)
        #expect(try reloadedContext.fetch(FetchDescriptor<UpNextQueueItemRecord>()).isEmpty)
    }

    @Test("A prune save failure keeps the last loaded queue and persisted order")
    func pruneSaveFailurePreservesLoadedQueue() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        for (sequence, episodeID) in ["missing", "kept"].enumerated() {
            context.insert(
                UpNextQueueItemRecord(
                    episodeID: episodeID,
                    podcastID: "show",
                    sequence: sequence
                )
            )
        }
        try context.save()
        let store = UpNextQueueStore { _ in throw QueueSaveFailure() }
        store.load(
            resolveEpisode: { _ in nil },
            mayPruneUnresolved: false,
            modelContext: context
        )

        store.load(
            resolveEpisode: { $0 == "kept" ? self.episode($0) : nil },
            mayPruneUnresolved: true,
            modelContext: context
        )

        #expect(store.items.map(\.episodeID) == ["missing", "kept"])
        #expect(store.lastErrorMessage?.contains("Unable to load Up Next") == true)
        try expectPersistedOrder(["missing", "kept"], container: container)
    }

    @Test("Visible reorder leaves an unresolved head in its fixed slot")
    func reorderWithUnresolvedHead() throws {
        let fixture = try loadedFixture(ids: ["unresolved", "b", "c"])

        #expect(
            fixture.store.reorderVisibleEpisodeIDs(
                ["c", "b"],
                modelContext: fixture.context
            )
        )

        #expect(fixture.store.items.map(\.episodeID) == ["unresolved", "c", "b"])
        try expectPersistedOrder(
            ["unresolved", "c", "b"],
            container: fixture.container
        )
    }

    @Test("Visible reorder leaves an unresolved middle slot fixed")
    func reorderWithUnresolvedMiddle() throws {
        let fixture = try loadedFixture(ids: ["b", "unresolved", "c"])

        #expect(
            fixture.store.reorderVisibleEpisodeIDs(
                ["c", "b"],
                modelContext: fixture.context
            )
        )

        #expect(fixture.store.items.map(\.episodeID) == ["c", "unresolved", "b"])
        try expectPersistedOrder(
            ["c", "unresolved", "b"],
            container: fixture.container
        )
    }

    @Test("Visible multi-row reorder persists through a fresh context")
    func multiRowVisibleReorder() throws {
        let fixture = try loadedFixture(ids: ["a", "unresolved", "b", "c", "d"])

        #expect(
            fixture.store.reorderVisibleEpisodeIDs(
                ["c", "d", "a", "b"],
                modelContext: fixture.context
            )
        )

        #expect(fixture.store.items.map(\.episodeID) == ["c", "unresolved", "d", "a", "b"])
        try expectPersistedOrder(
            ["c", "unresolved", "d", "a", "b"],
            container: fixture.container
        )
    }

    @Test("Bulk removal rolls back all selected episodes after one save failure")
    func bulkRemovalRollsBack() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        for (sequence, episodeID) in ["first", "second", "third"].enumerated() {
            context.insert(
                UpNextQueueItemRecord(
                    episodeID: episodeID,
                    podcastID: "show",
                    sequence: sequence
                )
            )
        }
        try context.save()
        let store = UpNextQueueStore { _ in throw QueueSaveFailure() }
        store.load(
            resolveEpisode: { _ in nil },
            mayPruneUnresolved: false,
            modelContext: context
        )

        #expect(!store.remove(episodeIDs: ["first", "third"], modelContext: context))
        #expect(store.items.map(\.episodeID) == ["first", "second", "third"])
        try expectPersistedOrder(["first", "second", "third"], container: container)
        #expect(store.lastErrorMessage?.contains("Unable to remove episodes from Up Next") == true)
    }

    @Test("No-op clear and podcast removal preserve an unconsumed error and skip notifications")
    func noOpMutationsStayHonest() throws {
        let fixture = try makeFixture()
        var changeCount = 0
        fixture.store.onQueueChanged = { changeCount += 1 }
        #expect(!fixture.store.reorderVisibleEpisodeIDs(["missing"], modelContext: fixture.context))
        let error = fixture.store.lastErrorMessage

        #expect(fixture.store.clear(modelContext: fixture.context))
        #expect(fixture.store.removeAll(forPodcastID: "missing", modelContext: fixture.context))

        #expect(fixture.store.lastErrorMessage == error)
        #expect(changeCount == 0)
    }

    private func makeFixture() throws -> (
        store: UpNextQueueStore,
        context: ModelContext,
        container: ModelContainer
    ) {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        return (UpNextQueueStore(), ModelContext(container), container)
    }

    private func loadedFixture(ids: [String]) throws -> (
        store: UpNextQueueStore,
        context: ModelContext,
        container: ModelContainer
    ) {
        let fixture = try makeFixture()
        for id in ids {
            #expect(fixture.store.enqueueLast(episode(id), modelContext: fixture.context))
        }
        return fixture
    }

    private func popEpisodeID(
        from store: UpNextQueueStore,
        modelContext: ModelContext
    ) -> String? {
        switch store.popNext(modelContext: modelContext) {
        case .item(let item):
            item.episodeID
        case .empty, .failure:
            nil
        }
    }

    private func expectPersistedOrder(
        _ expectedEpisodeIDs: [String],
        container: ModelContainer
    ) throws {
        let context = ModelContext(container)
        let records = try context.fetch(
            FetchDescriptor<UpNextQueueItemRecord>(sortBy: [SortDescriptor(\.sequence)])
        )
        #expect(records.map(\.episodeID) == expectedEpisodeIDs)
        #expect(records.map(\.sequence) == Array(expectedEpisodeIDs.indices))
    }

    private func episode(
        _ episodeID: String,
        podcastID: String = "https://example.com/feed.xml"
    ) -> EpisodeListItemSnapshot {
        .fixture(
            episodeID: episodeID,
            podcastID: podcastID,
            audioURL: "https://example.com/\(episodeID).mp3",
            guid: episodeID
        )
    }
}

private struct QueueSaveFailure: LocalizedError {
    var errorDescription: String? { "Simulated queue save failure" }
}
