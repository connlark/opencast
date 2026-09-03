import Foundation
import SQLite3

nonisolated extension SQLiteEpisodeSearchIndex {
    static func search(
        _ request: EpisodeSearchIndexRequest,
        in db: OpaquePointer
    ) throws -> [EpisodeSearchIndexHit] {
        guard !request.activePodcastIDs.isEmpty else {
            return []
        }
        if let allowedEpisodeIDs = request.allowedEpisodeIDs,
           allowedEpisodeIDs.isEmpty {
            return []
        }
        guard let compiled = EpisodeSearchQueryCompiler.compile(
            request.query,
            mode: request.mode
        ) else {
            return []
        }

        var candidatesByEpisodeID: [String: Candidate] = [:]
        for channel in compiled.primaryChannels {
            try Task.checkCancellation()
            if channel.kind == .prefix,
               candidatesByEpisodeID.count >= min(
                   relaxedCandidateThreshold,
                   request.limit
               ) {
                continue
            }
            merge(
                try candidates(
                    channel: channel,
                    canonicalPhrase: compiled.canonicalPhrase,
                    request: request,
                    db: db
                ),
                into: &candidatesByEpisodeID
            )
        }

        if candidatesByEpisodeID.count < min(
            relaxedCandidateThreshold,
            request.limit
        ), let relaxedChannel = compiled.relaxedChannel {
            try Task.checkCancellation()
            merge(
                try candidates(
                    channel: relaxedChannel,
                    canonicalPhrase: compiled.canonicalPhrase,
                    request: request,
                    db: db
                ),
                into: &candidatesByEpisodeID
            )
        }

        var substringCandidatesByEpisodeID: [String: Candidate] = [:]
        if candidatesByEpisodeID.count < request.limit {
            try Task.checkCancellation()
            merge(
                try visibleSubstringCandidates(
                    tokens: compiled.tokens,
                    canonicalPhrase: compiled.canonicalPhrase,
                    request: request,
                    db: db
                ),
                into: &substringCandidatesByEpisodeID
            )
        }

        let correctedVariants = try correctedVariants(
            tokens: compiled.tokens,
            request: request,
            db: db
        )
        for variant in correctedVariants {
            try Task.checkCancellation()
            merge(
                try candidates(
                    channel: variant.channel,
                    canonicalPhrase: variant.canonicalPhrase,
                    request: request,
                    db: db
                ),
                into: &candidatesByEpisodeID
            )
        }

        if request.mode == .fullText,
           let transcriptCompiled = EpisodeSearchQueryCompiler.compileTranscript(
            request.query
           ) {
            var transcriptCandidatesByPassageID: [String: TranscriptPassageCandidate] = [:]
            for channel in transcriptCompiled.primaryChannels {
                try Task.checkCancellation()
                if channel.kind == .prefix,
                   transcriptCandidatesByPassageID.count >= min(
                       relaxedCandidateThreshold,
                       request.limit
                   ) {
                    continue
                }
                mergeTranscript(
                    try transcriptCandidates(
                        channel: channel,
                        request: request,
                        db: db
                    ),
                    into: &transcriptCandidatesByPassageID
                )
            }
            if transcriptCandidatesByPassageID.count < min(
                relaxedCandidateThreshold,
                request.limit
            ),
               let relaxedChannel = transcriptCompiled.relaxedChannel {
                try Task.checkCancellation()
                mergeTranscript(
                    try transcriptCandidates(
                        channel: relaxedChannel,
                        request: request,
                        db: db
                    ),
                    into: &transcriptCandidatesByPassageID
                )
            }
            let correctedTranscriptVariants: [EpisodeSearchCompiledQuery.Variant]
            if let correctedVariant = correctedVariants.first {
                let correctedTokens = SearchTextNormalization.searchTokens(
                    in: correctedVariant.canonicalPhrase
                )
                correctedTranscriptVariants = [
                    EpisodeSearchQueryCompiler.correctedTranscriptVariant(
                        tokens: correctedTokens
                    ),
                    EpisodeSearchQueryCompiler.correctedTranscriptPrefixVariant(
                        tokens: correctedTokens
                    ),
                ].compactMap { $0 }
            } else {
                correctedTranscriptVariants = []
            }
            for variant in correctedTranscriptVariants {
                try Task.checkCancellation()
                mergeTranscript(
                    try transcriptCandidates(
                        channel: variant.channel,
                        request: request,
                        db: db
                    ),
                    into: &transcriptCandidatesByPassageID
                )
            }
            for transcriptCandidate in aggregateTranscriptCandidates(
                transcriptCandidatesByPassageID.values
            ) {
                fuseTranscriptCandidate(
                    transcriptCandidate,
                    into: &candidatesByEpisodeID
                )
            }
        }

        // FTS-ranked hits keep their tuned ordering; hits reachable only by
        // visible-substring containment supplement them afterward, ordered by
        // the channel's own deterministic score. A substring hit never
        // outranks or rescores an FTS hit.
        let rankedCandidates = candidatesByEpisodeID.values
            .sorted(by: Candidate.isOrderedBefore)
        let substringOnlyCandidates = substringCandidatesByEpisodeID.values
            .filter { candidatesByEpisodeID[$0.hit.episodeID] == nil }
            .sorted(by: Candidate.isOrderedBefore)
        let orderedCandidates = Array(
            (rankedCandidates + substringOnlyCandidates).prefix(request.limit)
        )
        var hits: [EpisodeSearchIndexHit] = []
        hits.reserveCapacity(orderedCandidates.count)
        for (index, candidate) in orderedCandidates.enumerated() {
            try Task.checkCancellation()
            let materialized = index < 10
                ? try materializeBodyEvidence(
                    for: candidate,
                    mode: request.mode,
                    db: db
                )
                : candidate
            hits.append(materialized.hit)
        }
        return hits
    }

    private static func correctedVariants(
        tokens: [String],
        request: EpisodeSearchIndexRequest,
        db: OpaquePointer
    ) throws -> [EpisodeSearchCompiledQuery.Variant] {
        var correctedTokens = tokens
        var correctionCount = 0
        for index in correctedTokens.indices {
            try Task.checkCancellation()
            guard correctionCount < EpisodeSearchSpelling.maximumCorrectedTermCount
            else {
                break
            }
            let observed = correctedTokens[index]
            guard EpisodeSearchSpelling.isEligibleTerm(observed),
                  try !vocabularyContains(
                    observed,
                    request: request,
                    db: db
                  )
            else {
                continue
            }
            let candidates = try correctionCandidates(
                for: observed,
                request: request,
                db: db
            )
            guard let correction = EpisodeSearchSpelling.bestCandidate(
                for: observed,
                from: candidates
            ) ?? EpisodeSearchSpelling.bestMorphologicalCandidate(
                for: observed,
                from: candidates
            ) else {
                continue
            }
            correctedTokens[index] = correction.term
            correctionCount += 1
        }

        guard correctionCount > 0 else {
            return []
        }
        return [
            EpisodeSearchQueryCompiler.correctedVariant(
                tokens: correctedTokens,
                mode: request.mode
            ),
            EpisodeSearchQueryCompiler.correctedPrefixVariant(
                tokens: correctedTokens,
                mode: request.mode
            ),
        ].compactMap { $0 }
    }

    private static func vocabularyContains(
        _ term: String,
        request: EpisodeSearchIndexRequest,
        db: OpaquePointer
    ) throws -> Bool {
        if try metadataTermExists(term, request: request, db: db) {
            return true
        }
        return try request.mode == .fullText
            && transcriptTermExists(term, request: request, db: db)
    }

    private static func correctionCandidates(
        for term: String,
        request: EpisodeSearchIndexRequest,
        db: OpaquePointer
    ) throws -> [EpisodeSearchCorrectionCandidate] {
        let hasEpisodeScope = request.allowedEpisodeIDs != nil
        let metadataEpisodeScopeSQL = hasEpisodeScope
            ? """

              AND episode_cache.episode_id
                  IN (SELECT value FROM json_each(?))
            """
            : ""
        let metadataColumnSQL = request.mode == .episodes
            ? "AND vocabulary.col IN ('title', 'podcast_title')"
            : ""
        let transcriptEpisodeScopeSQL = hasEpisodeScope
            ? """

              AND segment.episode_id
                  IN (SELECT value FROM json_each(?))
            """
            : ""
        let transcriptUnionSQL = request.mode == .fullText
            ? """

            UNION ALL

            SELECT vocabulary.term,
                   segment.episode_id,
                   'transcript' AS col,
                   1 AS source
            FROM candidate_terms
            JOIN \(transcriptVocabularyInstanceTableName) AS vocabulary
              ON vocabulary.term = candidate_terms.term
            JOIN \(transcriptSegmentTableName) AS segment
              ON segment.search_rowid = vocabulary.doc
            WHERE segment.podcast_id
                  IN (SELECT value FROM json_each(?))\(transcriptEpisodeScopeSQL)
            """
            : ""
        let sql = """
        WITH candidate_terms AS (
          SELECT DISTINCT term
          FROM episode_search_vocabulary_delete
          WHERE delete_key IN (SELECT value FROM json_each(?))
          ORDER BY term
          LIMIT 512
        ), scoped_occurrences AS (
          SELECT vocabulary.term,
                 episode_cache.episode_id,
                 vocabulary.col,
                 0 AS source
          FROM candidate_terms
          JOIN \(metadataVocabularyInstanceTableName) AS vocabulary
            ON vocabulary.term = candidate_terms.term
          JOIN episode_cache
            ON episode_cache.rowid = vocabulary.doc
          WHERE episode_cache.podcast_id
                IN (SELECT value FROM json_each(?))
            \(metadataColumnSQL)\(metadataEpisodeScopeSQL)\(transcriptUnionSQL)
        )
        SELECT term,
               COUNT(DISTINCT CASE
                 WHEN source = 0 AND col = 'title' THEN episode_id END
               ) AS title_document_count,
               COUNT(DISTINCT CASE
                 WHEN source = 0 AND col = 'podcast_title' THEN episode_id END
               ) AS podcast_title_document_count,
               COUNT(DISTINCT CASE
                 WHEN source = 0 AND col IN ('summary', 'show_notes')
                 THEN episode_id END
               ) AS body_document_count,
               COUNT(DISTINCT CASE
                 WHEN source = 1 THEN episode_id END
               ) AS transcript_document_count,
               COUNT(DISTINCT episode_id) AS document_count,
               COUNT(*) AS occurrence_count
        FROM scoped_occurrences
        GROUP BY term
        ORDER BY title_document_count DESC,
                 podcast_title_document_count DESC,
                 transcript_document_count DESC,
                 body_document_count DESC,
                 document_count DESC,
                 occurrence_count DESC,
                 term ASC
        LIMIT ?
        """
        var values: [EpisodeSearchCorrectionCandidate] = []
        try query(
            sql,
            operation: "episode search correction candidates",
            db: db,
            bindings: { statement in
                try bind(
                    jsonArray(EpisodeSearchSpelling.deletionKeys(for: term)),
                    at: 1,
                    statement: statement,
                    db: db,
                    operation: "episode search correction candidates"
                )
                try bind(
                    jsonArray(request.activePodcastIDs),
                    at: 2,
                    statement: statement,
                    db: db,
                    operation: "episode search correction candidates"
                )
                var nextIndex: Int32 = 3
                if let allowedEpisodeIDs = request.allowedEpisodeIDs {
                    try bind(
                        jsonArray(allowedEpisodeIDs),
                        at: nextIndex,
                        statement: statement,
                        db: db,
                        operation: "episode search correction candidates"
                    )
                    nextIndex += 1
                }
                if request.mode == .fullText {
                    try bind(
                        jsonArray(request.activePodcastIDs),
                        at: nextIndex,
                        statement: statement,
                        db: db,
                        operation: "episode search correction candidates"
                    )
                    nextIndex += 1
                    if let allowedEpisodeIDs = request.allowedEpisodeIDs {
                        try bind(
                            jsonArray(allowedEpisodeIDs),
                            at: nextIndex,
                            statement: statement,
                            db: db,
                            operation: "episode search correction candidates"
                        )
                        nextIndex += 1
                    }
                }
                try bind(
                    EpisodeSearchSpelling.candidateLimit,
                    at: nextIndex,
                    statement: statement,
                    db: db,
                    operation: "episode search correction candidates"
                )
            }
        ) { statement in
            values.append(
                EpisodeSearchCorrectionCandidate(
                    term: columnText(statement, 0) ?? "",
                    titleDocumentCount: Int(sqlite3_column_int64(statement, 1)),
                    podcastTitleDocumentCount: Int(sqlite3_column_int64(statement, 2)),
                    bodyDocumentCount: Int(sqlite3_column_int64(statement, 3)),
                    transcriptDocumentCount: Int(sqlite3_column_int64(statement, 4)),
                    documentCount: Int(sqlite3_column_int64(statement, 5)),
                    occurrenceCount: Int(sqlite3_column_int64(statement, 6))
                )
            )
        }
        return values
    }

    private static func candidates(
        channel: EpisodeSearchCompiledQuery.Channel,
        canonicalPhrase: String,
        request: EpisodeSearchIndexRequest,
        db: OpaquePointer
    ) throws -> [Candidate] {
        let hasEpisodeScope = request.allowedEpisodeIDs != nil
        let episodeScopeSQL = hasEpisodeScope
            ? """

              AND episode_cache.episode_id
                  IN (SELECT value FROM json_each(?))
            """
            : ""
        let sql = """
        SELECT episode_cache.episode_id,
               episode_cache.published_at,
               rank AS lexical_rank,
               evidence.title_canonical,
               evidence.podcast_title_canonical
        FROM episode_search_fts
        JOIN episode_cache
          ON episode_cache.rowid = episode_search_fts.rowid
        JOIN episode_search_evidence AS evidence
          ON evidence.search_rowid = episode_search_fts.rowid
        WHERE episode_search_fts MATCH ?
          AND rank MATCH 'bm25(12.0, 8.0, 3.0, 1.5)'
          AND episode_cache.podcast_id
              IN (SELECT value FROM json_each(?))\(episodeScopeSQL)
        ORDER BY rank ASC
        LIMIT ?
        """

        var values: [Candidate] = []
        try query(
            sql,
            operation: "episode search query",
            db: db,
            bindings: { statement in
                try bind(
                    channel.matchExpression,
                    at: 1,
                    statement: statement,
                    db: db,
                    operation: "episode search query"
                )
                try bind(
                    jsonArray(request.activePodcastIDs),
                    at: 2,
                    statement: statement,
                    db: db,
                    operation: "episode search query"
                )
                var nextIndex: Int32 = 3
                if let allowedEpisodeIDs = request.allowedEpisodeIDs {
                    try bind(
                        jsonArray(allowedEpisodeIDs),
                        at: nextIndex,
                        statement: statement,
                        db: db,
                        operation: "episode search query"
                    )
                    nextIndex += 1
                }
                try bind(
                    max(candidateLimit, request.limit),
                    at: nextIndex,
                    statement: statement,
                    db: db,
                    operation: "episode search query"
                )
            }
        ) { statement in
            let titleCanonical = columnText(statement, 3) ?? ""
            let podcastTitleCanonical = columnText(statement, 4) ?? ""
            let titleMatched = canonicalFieldMatches(
                titleCanonical,
                terms: channel.highlightTerms
            )
            let podcastTitleMatched = canonicalFieldMatches(
                podcastTitleCanonical,
                terms: channel.highlightTerms
            )
            var matchedFields: Set<EpisodeSearchMatchedField> = []
            if titleMatched {
                matchedFields.insert(.title)
            }
            if podcastTitleMatched {
                matchedFields.insert(.podcastTitle)
            }

            let publishedAt = columnDouble(statement, 1)
            let rawBM25 = sqlite3_column_double(statement, 2)
            let exactTitle = titleCanonical == canonicalPhrase
            let titlePhrase = containsCanonicalPhrase(
                canonicalPhrase,
                in: titleCanonical
            )
            let exactPodcastTitle = podcastTitleCanonical == canonicalPhrase
            let podcastTitlePhrase = containsCanonicalPhrase(
                canonicalPhrase,
                in: podcastTitleCanonical
            )
            let recencyBoost = recencyBoost(publishedAt: publishedAt)
            var finalScore = max(0, -rawBM25)
            finalScore += exactTitle ? 30 : 0
            finalScore += titlePhrase ? 16 : 0
            finalScore += exactPodcastTitle ? 20 : 0
            finalScore += podcastTitlePhrase ? 10 : 0
            finalScore += titleMatched ? 8 : 0
            finalScore += podcastTitleMatched ? 6 : 0
            finalScore += recencyBoost
            finalScore -= channel.kind.scorePenalty

            let trace = EpisodeSearchScoreTrace(
                channel: channel.kind,
                rawBM25: rawBM25,
                exactTitle: exactTitle,
                titlePhrase: titlePhrase,
                exactPodcastTitle: exactPodcastTitle,
                podcastTitlePhrase: podcastTitlePhrase,
                matchedFields: matchedFields,
                recencyBoost: recencyBoost,
                finalScore: finalScore
            )
            let hit = EpisodeSearchIndexHit(
                episodeID: columnText(statement, 0) ?? "",
                titleHighlightTerms: titleMatched
                    ? channel.highlightTerms
                    : [],
                podcastTitleHighlightTerms: podcastTitleMatched
                    ? channel.highlightTerms
                    : [],
                snippet: nil,
                snippetHighlightTerms: [],
                transcriptPassage: nil,
                scoreTrace: trace
            )
            values.append(
                Candidate(
                    hit: hit,
                    score: finalScore,
                    publishedAt: publishedAt,
                    highlightTerms: channel.highlightTerms
                )
            )
        }
        return values
    }

    /// The legacy matcher used substring containment on the visible fields
    /// ("cast" found "The Broadcast Hour"), and `unicode61` cannot split the
    /// user-visible terms inside an unsegmented CJK run. One bounded, scoped
    /// scan of the stored canonical visible titles preserves both recall
    /// paths for every script. Its hits only supplement FTS-ranked results —
    /// `search` orders substring-only hits after every FTS hit.
    private static func visibleSubstringCandidates(
        tokens: [String],
        canonicalPhrase: String,
        request: EpisodeSearchIndexRequest,
        db: OpaquePointer
    ) throws -> [Candidate] {
        let hasEpisodeScope = request.allowedEpisodeIDs != nil
        let episodeScopeSQL = hasEpisodeScope
            ? """

              AND episode_cache.episode_id
                  IN (SELECT value FROM json_each(?))
            """
            : ""
        let tokenSQL = tokens.map { _ in
            """
            (instr(evidence.title_canonical, ?) > 0
             OR instr(evidence.podcast_title_canonical, ?) > 0)
            """
        }
        .joined(separator: " AND ")
        let sql = """
        SELECT episode_cache.episode_id,
               episode_cache.published_at,
               evidence.title_canonical,
               evidence.podcast_title_canonical
        FROM episode_search_evidence AS evidence
        JOIN episode_cache
          ON episode_cache.rowid = evidence.search_rowid
        WHERE episode_cache.podcast_id
              IN (SELECT value FROM json_each(?))\(episodeScopeSQL)
          AND \(tokenSQL)
        ORDER BY episode_cache.published_at DESC,
                 episode_cache.episode_id ASC
        LIMIT ?
        """

        var values: [Candidate] = []
        try query(
            sql,
            operation: "episode search visible substring supplement",
            db: db,
            bindings: { statement in
                var nextIndex: Int32 = 1
                try bind(
                    jsonArray(request.activePodcastIDs),
                    at: nextIndex,
                    statement: statement,
                    db: db,
                    operation: "episode search visible substring supplement"
                )
                nextIndex += 1
                if let allowedEpisodeIDs = request.allowedEpisodeIDs {
                    try bind(
                        jsonArray(allowedEpisodeIDs),
                        at: nextIndex,
                        statement: statement,
                        db: db,
                        operation: "episode search visible substring supplement"
                    )
                    nextIndex += 1
                }
                for token in tokens {
                    try bind(
                        token,
                        at: nextIndex,
                        statement: statement,
                        db: db,
                        operation: "episode search visible substring supplement"
                    )
                    nextIndex += 1
                    try bind(
                        token,
                        at: nextIndex,
                        statement: statement,
                        db: db,
                        operation: "episode search visible substring supplement"
                    )
                    nextIndex += 1
                }
                try bind(
                    max(candidateLimit, request.limit),
                    at: nextIndex,
                    statement: statement,
                    db: db,
                    operation: "episode search visible substring supplement"
                )
            }
        ) { statement in
            let titleCanonical = columnText(statement, 2) ?? ""
            let podcastTitleCanonical = columnText(statement, 3) ?? ""
            let titleMatchCount = tokens.count { token in
                titleCanonical.contains(token)
            }
            let podcastTitleMatchCount = tokens.count { token in
                podcastTitleCanonical.contains(token)
            }
            let titleMatched = titleMatchCount > 0
            let podcastTitleMatched = podcastTitleMatchCount > 0
            var matchedFields: Set<EpisodeSearchMatchedField> = []
            if titleMatched {
                matchedFields.insert(.title)
            }
            if podcastTitleMatched {
                matchedFields.insert(.podcastTitle)
            }
            let publishedAt = columnDouble(statement, 1)
            let exactTitle = titleCanonical == canonicalPhrase
            let titlePhrase = containsCanonicalPhrase(
                canonicalPhrase,
                in: titleCanonical
            )
            let exactPodcastTitle = podcastTitleCanonical == canonicalPhrase
            let podcastTitlePhrase = containsCanonicalPhrase(
                canonicalPhrase,
                in: podcastTitleCanonical
            )
            let recencyBoost = recencyBoost(publishedAt: publishedAt)
            var finalScore = Double(titleMatchCount) * 4
            finalScore += Double(podcastTitleMatchCount) * 3
            finalScore += exactTitle ? 30 : 0
            finalScore += titlePhrase ? 16 : 0
            finalScore += exactPodcastTitle ? 20 : 0
            finalScore += podcastTitlePhrase ? 10 : 0
            finalScore += recencyBoost
            finalScore -= EpisodeSearchIndexChannel.visibleSubstring
                .scorePenalty
            let trace = EpisodeSearchScoreTrace(
                channel: .visibleSubstring,
                rawBM25: 0,
                exactTitle: exactTitle,
                titlePhrase: titlePhrase,
                exactPodcastTitle: exactPodcastTitle,
                podcastTitlePhrase: podcastTitlePhrase,
                matchedFields: matchedFields,
                recencyBoost: recencyBoost,
                finalScore: finalScore
            )
            let hit = EpisodeSearchIndexHit(
                episodeID: columnText(statement, 0) ?? "",
                titleHighlightTerms: titleMatched ? tokens : [],
                podcastTitleHighlightTerms: podcastTitleMatched ? tokens : [],
                snippet: nil,
                snippetHighlightTerms: [],
                transcriptPassage: nil,
                scoreTrace: trace
            )
            values.append(
                Candidate(
                    hit: hit,
                    score: finalScore,
                    publishedAt: publishedAt,
                    highlightTerms: tokens
                )
            )
        }
        return values
    }

    private static func transcriptCandidates(
        channel: EpisodeSearchCompiledQuery.Channel,
        request: EpisodeSearchIndexRequest,
        db: OpaquePointer
    ) throws -> [TranscriptPassageCandidate] {
        let hasEpisodeScope = request.allowedEpisodeIDs != nil
        let episodeScopeSQL = hasEpisodeScope
            ? """

              AND segment.episode_id
                  IN (SELECT value FROM json_each(?))
            """
            : ""
        let sql = """
        SELECT segment.segment_id,
               segment.episode_id,
               episode_cache.published_at,
               segment.start_seconds,
               segment.end_seconds,
               rank AS lexical_rank,
               segment.text
        FROM episode_transcript_search_fts
        JOIN episode_transcript_search_segment AS segment
          ON segment.search_rowid = episode_transcript_search_fts.rowid
        JOIN episode_cache
          ON episode_cache.episode_id = segment.episode_id
        WHERE episode_transcript_search_fts MATCH ?
          AND rank MATCH 'bm25(1.0)'
          AND segment.podcast_id
              IN (SELECT value FROM json_each(?))\(episodeScopeSQL)
        ORDER BY rank ASC
        LIMIT ?
        """
        var values: [TranscriptPassageCandidate] = []
        try query(
            sql,
            operation: "episode transcript search query",
            db: db,
            bindings: { statement in
                try bind(
                    channel.matchExpression,
                    at: 1,
                    statement: statement,
                    db: db,
                    operation: "episode transcript search query"
                )
                try bind(
                    jsonArray(request.activePodcastIDs),
                    at: 2,
                    statement: statement,
                    db: db,
                    operation: "episode transcript search query"
                )
                var nextIndex: Int32 = 3
                if let allowedEpisodeIDs = request.allowedEpisodeIDs {
                    try bind(
                        jsonArray(allowedEpisodeIDs),
                        at: nextIndex,
                        statement: statement,
                        db: db,
                        operation: "episode transcript search query"
                    )
                    nextIndex += 1
                }
                try bind(
                    max(transcriptCandidateLimit, request.limit),
                    at: nextIndex,
                    statement: statement,
                    db: db,
                    operation: "episode transcript search query"
                )
            }
        ) { statement in
            let rawBM25 = sqlite3_column_double(statement, 5)
            let score = transcriptChannelBaseScore(channel.kind)
                + min(12, max(0, -rawBM25))
            values.append(
                TranscriptPassageCandidate(
                    segmentID: columnText(statement, 0) ?? "",
                    episodeID: columnText(statement, 1) ?? "",
                    publishedAt: columnDouble(statement, 2),
                    startSeconds: sqlite3_column_double(statement, 3),
                    endSeconds: sqlite3_column_double(statement, 4),
                    rawBM25: rawBM25,
                    score: score,
                    text: columnText(statement, 6) ?? "",
                    highlightTerms: channel.highlightTerms,
                    channel: channel.kind
                )
            )
        }
        return values
    }

    private static func transcriptChannelBaseScore(
        _ channel: EpisodeSearchIndexChannel
    ) -> Double {
        switch channel {
        case .exact:
            14
        case .prefix:
            11
        case .relaxed:
            7
        case .corrected:
            10
        case .visibleSubstring:
            10
        case .transcript:
            14
        }
    }

    private static func mergeTranscript(
        _ candidates: [TranscriptPassageCandidate],
        into candidatesByPassageID: inout [String: TranscriptPassageCandidate]
    ) {
        for candidate in candidates {
            let key = "\(candidate.episodeID)\u{1F}\(candidate.segmentID)"
            if let existing = candidatesByPassageID[key],
               !TranscriptPassageCandidate.isOrderedBefore(candidate, existing) {
                continue
            }
            candidatesByPassageID[key] = candidate
        }
    }

    private static func aggregateTranscriptCandidates(
        _ candidates: some Sequence<TranscriptPassageCandidate>
    ) -> [TranscriptEpisodeCandidate] {
        let grouped = Dictionary(grouping: candidates, by: \.episodeID)
        return grouped.values.compactMap { episodeCandidates in
            let ordered = episodeCandidates.sorted(
                by: TranscriptPassageCandidate.isOrderedBefore
            )
            guard let best = ordered.first else {
                return nil
            }
            var score = best.score
            if ordered.count > 1 {
                score += min(4, ordered[1].score * 0.2)
            }
            if ordered.count > 2 {
                score += min(2, ordered[2].score * 0.1)
            }
            let recency = recencyBoost(publishedAt: best.publishedAt)
            return TranscriptEpisodeCandidate(
                bestPassage: best,
                score: score + recency,
                recencyBoost: recency
            )
        }
    }

    private static func fuseTranscriptCandidate(
        _ transcriptCandidate: TranscriptEpisodeCandidate,
        into candidatesByEpisodeID: inout [String: Candidate]
    ) {
        let bestPassage = transcriptCandidate.bestPassage
        let existing = candidatesByEpisodeID[bestPassage.episodeID]
        let finalScore: Double
        if let existing {
            finalScore = existing.score
                + min(8, transcriptCandidate.score * 0.35)
        } else {
            finalScore = transcriptCandidate.score
        }

        var matchedFields = existing?.hit.scoreTrace.matchedFields ?? []
        matchedFields.insert(.transcript)
        let priorTrace = existing?.hit.scoreTrace
        let trace = EpisodeSearchScoreTrace(
            channel: priorTrace?.channel ?? .transcript,
            rawBM25: priorTrace?.rawBM25 ?? bestPassage.rawBM25,
            exactTitle: priorTrace?.exactTitle ?? false,
            titlePhrase: priorTrace?.titlePhrase ?? false,
            exactPodcastTitle: priorTrace?.exactPodcastTitle ?? false,
            podcastTitlePhrase: priorTrace?.podcastTitlePhrase ?? false,
            matchedFields: matchedFields,
            recencyBoost: priorTrace?.recencyBoost
                ?? transcriptCandidate.recencyBoost,
            finalScore: finalScore
        )
        // A transcript hit must explain itself: excerpt the best passage
        // around its first matched term, falling back to the passage head so
        // transcript-only rows never render bare.
        let snippet = matchingSnippet(
            in: bestPassage.text,
            terms: bestPassage.highlightTerms
        ) ?? truncatedPassage(bestPassage.text)
        let hit = EpisodeSearchIndexHit(
            episodeID: bestPassage.episodeID,
            titleHighlightTerms: existing?.hit.titleHighlightTerms ?? [],
            podcastTitleHighlightTerms:
                existing?.hit.podcastTitleHighlightTerms ?? [],
            snippet: snippet,
            snippetHighlightTerms: snippet == nil
                ? []
                : bestPassage.highlightTerms,
            transcriptPassage: EpisodeSearchPassageEvidence(
                segmentID: bestPassage.segmentID,
                startSeconds: bestPassage.startSeconds,
                endSeconds: bestPassage.endSeconds
            ),
            scoreTrace: trace
        )
        candidatesByEpisodeID[bestPassage.episodeID] = Candidate(
            hit: hit,
            score: finalScore,
            publishedAt: bestPassage.publishedAt,
            highlightTerms: existing?.highlightTerms
                ?? bestPassage.highlightTerms
        )
    }

    private static func merge(
        _ candidates: [Candidate],
        into candidatesByEpisodeID: inout [String: Candidate]
    ) {
        for candidate in candidates {
            if let existing = candidatesByEpisodeID[candidate.hit.episodeID],
               !Candidate.isOrderedBefore(candidate, existing) {
                continue
            }
            candidatesByEpisodeID[candidate.hit.episodeID] = candidate
        }
    }

    private static func materializeBodyEvidence(
        for candidate: Candidate,
        mode: EpisodeSearchMode,
        db: OpaquePointer
    ) throws -> Candidate {
        let existingFields = candidate.hit.scoreTrace.matchedFields
        guard mode == .fullText,
              !existingFields.contains(.title),
              !existingFields.contains(.podcastTitle),
              !candidate.highlightTerms.isEmpty
        else {
            return candidate
        }

        var evidence = (summary: "", showNotes: "")
        try query(
            """
            SELECT body_data
            FROM episode_search_evidence_body
            WHERE search_rowid = (
              SELECT rowid FROM episode_cache WHERE episode_id = ?
            )
            LIMIT 1
            """,
            operation: "episode search evidence load",
            db: db,
            bindings: { statement in
                try bind(
                    candidate.hit.episodeID,
                    at: 1,
                    statement: statement,
                    db: db,
                    operation: "episode search evidence load"
                )
            }
        ) { statement in
            evidence = try decompressedSearchEvidence(
                columnData(statement, 0),
                operation: "episode search evidence load"
            )
        }

        let summaryMatched = fieldMatches(
            evidence.summary,
            terms: candidate.highlightTerms
        )
        let showNotesMatched = fieldMatches(
            evidence.showNotes,
            terms: candidate.highlightTerms
        )
        guard summaryMatched || showNotesMatched else {
            return candidate
        }

        var matchedFields = existingFields
        if summaryMatched {
            matchedFields.insert(.summary)
        }
        if showNotesMatched {
            matchedFields.insert(.showNotes)
        }
        let oldTrace = candidate.hit.scoreTrace
        let trace = EpisodeSearchScoreTrace(
            channel: oldTrace.channel,
            rawBM25: oldTrace.rawBM25,
            exactTitle: oldTrace.exactTitle,
            titlePhrase: oldTrace.titlePhrase,
            exactPodcastTitle: oldTrace.exactPodcastTitle,
            podcastTitlePhrase: oldTrace.podcastTitlePhrase,
            matchedFields: matchedFields,
            recencyBoost: oldTrace.recencyBoost,
            finalScore: oldTrace.finalScore
        )
        let bodySnippet: String? = if summaryMatched {
            matchingSnippet(
                in: evidence.summary,
                terms: candidate.highlightTerms
            )
        } else {
            matchingSnippet(
                in: evidence.showNotes,
                terms: candidate.highlightTerms
            )
        }
        // Legacy search surfaced the summary/show-notes snippet, so body
        // evidence wins; a transcript excerpt already on the hit stays only
        // when no body snippet materialized.
        let snippet = bodySnippet ?? candidate.hit.snippet
        let snippetHighlightTerms = bodySnippet == nil
            ? candidate.hit.snippetHighlightTerms
            : candidate.highlightTerms
        return Candidate(
            hit: EpisodeSearchIndexHit(
                episodeID: candidate.hit.episodeID,
                titleHighlightTerms: candidate.hit.titleHighlightTerms,
                podcastTitleHighlightTerms:
                    candidate.hit.podcastTitleHighlightTerms,
                snippet: snippet,
                snippetHighlightTerms: snippetHighlightTerms,
                transcriptPassage: candidate.hit.transcriptPassage,
                scoreTrace: trace
            ),
            score: candidate.score,
            publishedAt: candidate.publishedAt,
            highlightTerms: candidate.highlightTerms
        )
    }

    private static func recencyBoost(publishedAt: TimeInterval?) -> Double {
        guard let publishedAt else {
            return 0
        }
        let fiveYears: TimeInterval = 5 * 365.25 * 24 * 60 * 60
        let age = max(0, Date.now.timeIntervalSince1970 - publishedAt)
        return 0.2 / (1 + age / fiveYears)
    }

    private static func fieldMatches(
        _ text: String,
        terms: [String]
    ) -> Bool {
        guard !terms.isEmpty else {
            return false
        }
        let fieldTokens = SearchTextNormalization.searchTokens(in: text)
        return fieldTokens.contains { fieldToken in
            terms.contains { term in
                fieldToken == term
                    || (term.count >= 2 && fieldToken.hasPrefix(term))
            }
        }
    }

    /// `fieldMatches` for text that is already canonical (normalized tokens
    /// joined by single spaces), so the hot per-row path never re-tokenizes.
    private static func canonicalFieldMatches(
        _ canonicalText: String,
        terms: [String]
    ) -> Bool {
        guard !terms.isEmpty else {
            return false
        }
        return canonicalText.split(separator: " ").contains { fieldToken in
            terms.contains { term in
                fieldToken == term
                    || (term.count >= 2 && fieldToken.hasPrefix(term))
            }
        }
    }

    private static func containsCanonicalPhrase(
        _ phrase: String,
        in text: String
    ) -> Bool {
        !phrase.isEmpty
            && (" " + text + " ").contains(" " + phrase + " ")
    }

    private static func truncatedPassage(_ text: String) -> String? {
        let words = text.split(whereSeparator: \Character.isWhitespace)
        guard !words.isEmpty else {
            return nil
        }
        let endIndex = min(words.endIndex, words.startIndex + 24)
        let trailing = endIndex == words.endIndex ? "" : " …"
        return words[words.startIndex..<endIndex].joined(separator: " ")
            + trailing
    }

    private static func matchingSnippet(
        in text: String,
        terms: [String]
    ) -> String? {
        let words = text.split(whereSeparator: \Character.isWhitespace)
        guard !words.isEmpty,
              let matchIndex = words.firstIndex(where: {
                  fieldMatches(String($0), terms: terms)
              })
        else {
            return nil
        }
        let startIndex = max(words.startIndex, matchIndex - 8)
        let endIndex = min(words.endIndex, startIndex + 24)
        let leading = startIndex == words.startIndex ? "" : "… "
        let trailing = endIndex == words.endIndex ? "" : " …"
        return leading
            + words[startIndex..<endIndex].joined(separator: " ")
            + trailing
    }


    private static func metadataTermExists(
        _ term: String,
        request: EpisodeSearchIndexRequest,
        db: OpaquePointer
    ) throws -> Bool {
        let episodeScopeSQL = request.allowedEpisodeIDs == nil
            ? ""
            : """

              AND episode_cache.episode_id
                  IN (SELECT value FROM json_each(?))
            """
        let fields = request.mode == .fullText
            ? "{title podcast_title summary show_notes}"
            : "{title podcast_title}"
        let expression = "\(fields) : (\(quotedFTSLiteral(term)))"
        var exists = false
        try query(
            """
            SELECT 1
            FROM episode_search_fts
            JOIN episode_cache
              ON episode_cache.rowid = episode_search_fts.rowid
            WHERE episode_search_fts MATCH ?
              AND episode_cache.podcast_id
                  IN (SELECT value FROM json_each(?))\(episodeScopeSQL)
            LIMIT 1
            """,
            operation: "episode search vocabulary lookup",
            db: db,
            bindings: { statement in
                try bind(expression, at: 1, statement: statement, db: db,
                         operation: "episode search vocabulary lookup")
                try bind(jsonArray(request.activePodcastIDs), at: 2,
                         statement: statement, db: db,
                         operation: "episode search vocabulary lookup")
                if let allowedEpisodeIDs = request.allowedEpisodeIDs {
                    try bind(jsonArray(allowedEpisodeIDs), at: 3,
                             statement: statement, db: db,
                             operation: "episode search vocabulary lookup")
                }
            }
        ) { _ in
            exists = true
        }
        return exists
    }

    private static func transcriptTermExists(
        _ term: String,
        request: EpisodeSearchIndexRequest,
        db: OpaquePointer
    ) throws -> Bool {
        let episodeScopeSQL = request.allowedEpisodeIDs == nil
            ? ""
            : """

              AND segment.episode_id
                  IN (SELECT value FROM json_each(?))
            """
        var exists = false
        try query(
            """
            SELECT 1
            FROM episode_transcript_search_fts
            JOIN episode_transcript_search_segment AS segment
              ON segment.search_rowid = episode_transcript_search_fts.rowid
            WHERE episode_transcript_search_fts MATCH ?
              AND segment.podcast_id
                  IN (SELECT value FROM json_each(?))\(episodeScopeSQL)
            LIMIT 1
            """,
            operation: "episode transcript search vocabulary lookup",
            db: db,
            bindings: { statement in
                try bind(quotedFTSLiteral(term), at: 1,
                         statement: statement, db: db,
                         operation:
                            "episode transcript search vocabulary lookup")
                try bind(jsonArray(request.activePodcastIDs), at: 2,
                         statement: statement, db: db,
                         operation:
                            "episode transcript search vocabulary lookup")
                if let allowedEpisodeIDs = request.allowedEpisodeIDs {
                    try bind(jsonArray(allowedEpisodeIDs), at: 3,
                             statement: statement, db: db,
                             operation:
                                "episode transcript search vocabulary lookup")
                }
            }
        ) { _ in
            exists = true
        }
        return exists
    }

    private static func quotedFTSLiteral(_ term: String) -> String {
        "\"\(term.replacing("\"", with: "\"\""))\""
    }


    private struct Candidate {
        let hit: EpisodeSearchIndexHit
        let score: Double
        let publishedAt: TimeInterval?
        let highlightTerms: [String]

        static func isOrderedBefore(_ lhs: Self, _ rhs: Self) -> Bool {
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            let lhsDate = lhs.publishedAt ?? -.infinity
            let rhsDate = rhs.publishedAt ?? -.infinity
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }
            return lhs.hit.episodeID < rhs.hit.episodeID
        }
    }

    private struct TranscriptPassageCandidate {
        let segmentID: String
        let episodeID: String
        let publishedAt: TimeInterval?
        let startSeconds: TimeInterval
        let endSeconds: TimeInterval
        let rawBM25: Double
        let score: Double
        let text: String
        let highlightTerms: [String]
        let channel: EpisodeSearchIndexChannel

        static func isOrderedBefore(_ lhs: Self, _ rhs: Self) -> Bool {
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            if lhs.channel != rhs.channel {
                return lhs.channel.scorePenalty < rhs.channel.scorePenalty
            }
            if lhs.startSeconds != rhs.startSeconds {
                return lhs.startSeconds < rhs.startSeconds
            }
            return lhs.segmentID < rhs.segmentID
        }
    }

    private struct TranscriptEpisodeCandidate {
        let bestPassage: TranscriptPassageCandidate
        let score: Double
        let recencyBoost: Double
    }
}
