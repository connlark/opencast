import AppIntents
import CoreSpotlight

nonisolated struct OpenCastPodcastQuery: EntityStringQuery, IndexedEntityQuery {
    func entities(for identifiers: [String]) async throws -> [OpenCastPodcastEntity] {
        guard identifiers.count <= OpenCastEntityCatalog.queryLimit else { throw OpenCastSystemActionError.queryTooLarge }
        let catalog = try await OpenCastIntentAccess.catalog()
        let byID = Dictionary(catalog.shows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return identifiers.compactMap { byID[$0] }
    }

    func entities(matching string: String) async throws -> [OpenCastPodcastEntity] {
        let catalog = try await OpenCastIntentAccess.catalog()
        return Array(catalog.shows.filter { $0.title.localizedStandardContains(string) }.prefix(OpenCastEntityCatalog.queryLimit))
    }

    func suggestedEntities() async throws -> [OpenCastPodcastEntity] {
        Array(try await OpenCastIntentAccess.catalog().shows.prefix(30))
    }

    func reindexEntities(for identifiers: [String], indexDescription: CSSearchableIndexDescription) async throws {
        try await reindexAllEntities(indexDescription: indexDescription)
    }

    func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
        try await OpenCastEntityIndex.shared.rebuild(OpenCastIntentAccess.catalog())
    }
}
