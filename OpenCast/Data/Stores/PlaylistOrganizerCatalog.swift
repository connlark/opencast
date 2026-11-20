import Foundation
import NaturalLanguage

nonisolated struct PlaylistOrganizerCatalog: Sendable {
    let lines: [EpisodeMetadataLine]
    let lexicalIndex: EpisodeMetadataIndex
    let vectorIndex: EpisodeVectorIndex?
    let language: NLLanguage

    @concurrent
    static func build(episodes: [PlaylistOrganizerEpisode]) async throws -> PlaylistOrganizerCatalog {
        let lines = PlaylistOrganizerInputBuilder.metadataLines(for: episodes)
        try Task.checkCancellation()
        let lexicalIndex = EpisodeMetadataIndex(lines: lines)
        let language = EpisodeWordVectorEmbedder.language(for: lines)
        let vectorIndex = try await EpisodeWordVectorEmbedder.index(lines: lines, language: language)
        return PlaylistOrganizerCatalog(
            lines: lines,
            lexicalIndex: lexicalIndex,
            vectorIndex: vectorIndex,
            language: language
        )
    }

    @concurrent
    func window(for query: String) async -> EpisodeCandidateWindow {
        let lexical = lexicalIndex.informativeMatches(query)
        let semantic = await semanticRanking(for: query) ?? []
        return EpisodeCandidateRanking.lexicalFirst(lexical: lexical, semantic: semantic)
    }

    @concurrent
    func additions(for query: String, excluding: Set<Int>, limit: Int = 30) async -> [Int] {
        guard limit > 0 else {
            return []
        }
        let semantic = await semanticRanking(for: query)
        if semantic == nil, EpisodeMetadataTokenizer.queryTerms(query).isEmpty {
            return Array(lines.map(\.position).filter { !excluding.contains($0) }.sorted().prefix(limit))
        }
        let window = EpisodeCandidateRanking.lexicalFirst(
            lexical: lexicalIndex.search(query, limit: .max),
            semantic: semantic ?? [],
            fill: limit,
            limit: limit,
            excluding: excluding
        )
        return Array(window.rankedPositions.prefix(limit))
    }

    private func semanticRanking(for query: String) async -> [EpisodeMetadataMatch]? {
        guard let vectorIndex,
              let vector = await EpisodeWordVectorEmbedder.queryVector(query, language: language)
        else {
            return nil
        }
        return vectorIndex.rank(vector)
    }
}
