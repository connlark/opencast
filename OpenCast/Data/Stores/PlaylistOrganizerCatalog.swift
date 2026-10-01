import Foundation
import NaturalLanguage

/// One show's retrieval state: its metadata lines, the BM25 index and, when
/// the show's language has a word embedding on this device, the word-vector
/// index. Built once per sheet and queried for every request and search.
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

    /// The production candidate window for a request: the lines holding an
    /// informative term in BM25 order (at most 150), then the 30 nearest
    /// other lines by word vector.
    @concurrent
    func window(for query: String) async -> EpisodeCandidateWindow {
        let lexical = lexicalIndex.informativeMatches(query)
        let semantic = await semanticRanking(for: query) ?? []
        return EpisodeCandidateRanking.lexicalFirst(lexical: lexical, semantic: semantic)
    }

    /// Ranked positions for the "Add Episodes…" list: every word match first,
    /// then the nearest lines by word vector, cut to `limit`. A query with
    /// neither a searchable word nor a vector lists the newest episodes.
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
