import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Recent searches store")
struct RecentSearchesStoreTests {
    @Test("Recording trims queries and ignores blanks")
    func recordingTrimsQueriesAndIgnoresBlanks() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = RecentSearchesStore()

        store.record("  Swift Podcasts\n", modelContext: context)
        store.record("   \n", modelContext: context)

        #expect(store.queries == ["Swift Podcasts"])
    }

    @Test("Recording deduplicates case insensitively and moves queries to the front")
    func recordingDeduplicatesAndMovesToFront() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = RecentSearchesStore()

        store.record("First", modelContext: context)
        store.record("Second", modelContext: context)
        store.record("FIRST", modelContext: context)

        #expect(store.queries == ["FIRST", "Second"])
    }

    @Test("Recent searches retain only ten queries")
    func recentSearchesRetainOnlyTenQueries() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = RecentSearchesStore()

        for index in 0..<12 {
            store.record("Query \(index)", modelContext: context)
        }

        #expect(
            store.queries == [
                "Query 11", "Query 10", "Query 9", "Query 8", "Query 7",
                "Query 6", "Query 5", "Query 4", "Query 3", "Query 2",
            ]
        )
    }

    @Test("Recent searches persist across store instances")
    func recentSearchesPersistAcrossStoreInstances() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = RecentSearchesStore()

        store.record("Persistent Search", modelContext: context)

        let reloadedStore = RecentSearchesStore()
        reloadedStore.load(modelContext: context)

        #expect(reloadedStore.queries == ["Persistent Search"])
    }

    @Test("Clearing removes persisted recent searches")
    func clearingRemovesPersistedRecentSearches() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = RecentSearchesStore()
        store.record("Temporary Search", modelContext: context)

        store.clear(modelContext: context)

        let reloadedStore = RecentSearchesStore()
        reloadedStore.load(modelContext: context)
        #expect(store.queries.isEmpty)
        #expect(reloadedStore.queries.isEmpty)
    }
}
