import AppIntents
import CoreSpotlight

nonisolated struct OpenCastEpisodeQuery: EntityStringQuery, IndexedEntityQuery {
    func entities(for identifiers: [String]) async throws -> [OpenCastEpisodeEntity] {
        guard identifiers.count <= OpenCastEntityCatalog.queryLimit else { throw OpenCastSystemActionError.queryTooLarge }
        // Saved actions may refer to older cached episodes outside Spotlight's
        // latest-100 window. Resolve those IDs against the live cache as well.
        return try await resolve(identifiers)
    }

    @MainActor
    private func resolve(_ identifiers: [String]) async throws -> [OpenCastEpisodeEntity] {
        _ = try await OpenCastIntentAccess.catalog()
        let model = OpenCastAppRuntime.shared.appModel
        return identifiers.compactMap { id in
            guard let episode = model.episodeSnapshot(for: id), model.library.activePodcastIDs.contains(episode.podcastID) else { return nil }
            return OpenCastEpisodeEntity(episode: episode, show: OpenCastPodcastEntity(id: episode.podcastID, title: episode.podcastTitle))
        }
    }

    func entities(matching string: String) async throws -> [OpenCastEpisodeEntity] {
        let catalog = try await OpenCastIntentAccess.catalog()
        return Array(catalog.episodes.filter {
            $0.title.localizedStandardContains(string) || ($0.showName?.localizedStandardContains(string) == true)
        }.prefix(OpenCastEntityCatalog.queryLimit))
    }

    func suggestedEntities() async throws -> [OpenCastEpisodeEntity] {
        Array(try await OpenCastIntentAccess.catalog().episodes.prefix(30))
    }

    func reindexEntities(for identifiers: [String], indexDescription: CSSearchableIndexDescription) async throws {
        try await reindexAllEntities(indexDescription: indexDescription)
    }

    func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
        try await OpenCastEntityIndex.shared.rebuild(OpenCastIntentAccess.catalog())
    }
}
