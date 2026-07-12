import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Recent searches store")
struct RecentSearchesStoreTests {
    @Test("Recent searches default to empty")
    func recentSearchesDefaultToEmpty() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = RecentSearchesStore()

        store.load(modelContext: context)

        #expect(store.queries.isEmpty)
    }

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

        #expect(store.queries == (2..<12).reversed().map { "Query \($0)" })
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
