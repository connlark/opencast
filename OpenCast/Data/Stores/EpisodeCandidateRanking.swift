/// Hard-priority fusion of the word-matching and word-vector rankings. Rank
/// fusion and weighted score blends let the weaker lane outvote a decisive
/// word match; here a matching line always outranks a merely similar one.
nonisolated enum EpisodeCandidateRanking {
    static let defaultFill = 30
    static let defaultLexicalLimit = 150

    /// The lexical block (already BM25-ordered) capped at `limit`, then the
    /// first `fill` semantic positions not already taken and not in
    /// `excluding`. The fill never displaces a lexical line.
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
            fillCount: filled.count,
            isInformative: !lexical.isEmpty
        )
    }
}
