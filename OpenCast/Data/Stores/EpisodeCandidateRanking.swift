/// A matching line always outranks a merely similar one: rank fusion or a score blend would let
/// the word-vector lane outvote a decisive word match.
nonisolated enum EpisodeCandidateRanking {
    static let defaultFill = 30
    static let defaultLexicalLimit = 150

    /// `lexical` must already be BM25-ordered.
    static func lexicalFirst(
        lexical: [EpisodeMetadataMatch],
        semantic: [EpisodeMetadataMatch],
        fill: Int = defaultFill,
        limit: Int = defaultLexicalLimit,
        excluding: Set<Int> = []
    ) -> EpisodeCandidateWindow {
        var taken = excluding
        var block: [Int] = []
        for match in lexical {
            guard block.count < limit else {
                break
            }
            if taken.insert(match.position).inserted {
                block.append(match.position)
            }
        }
        var filled: [Int] = []
        for match in semantic {
            guard filled.count < fill else {
                break
            }
            if taken.insert(match.position).inserted {
                filled.append(match.position)
            }
        }
        let ranked = block + filled
        return EpisodeCandidateWindow(
            rankedPositions: ranked,
            positions: ranked.sorted(),
            lexicalCount: block.count,
            fillCount: filled.count
        )
    }
}
