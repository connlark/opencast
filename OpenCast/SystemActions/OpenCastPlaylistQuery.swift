import AppIntents

nonisolated struct OpenCastPlaylistQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [OpenCastPlaylistEntity] {
        guard identifiers.count <= OpenCastEntityCatalog.queryLimit else { throw OpenCastSystemActionError.queryTooLarge }
        let playlists = try await OpenCastIntentAccess.playlists()
        let byID = Dictionary(playlists.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return identifiers.compactMap { byID[$0] }
    }

    func entities(matching string: String) async throws -> [OpenCastPlaylistEntity] {
        let playlists = try await OpenCastIntentAccess.playlists()
        return Array(playlists.filter { $0.name.localizedStandardContains(string) }.prefix(OpenCastEntityCatalog.queryLimit))
    }

    func suggestedEntities() async throws -> [OpenCastPlaylistEntity] {
        Array(try await OpenCastIntentAccess.playlists().prefix(30))
    }
}
