import Foundation

nonisolated struct EpisodeSearchCompiledQuery: Sendable {
    struct Channel: Sendable {
        let kind: EpisodeSearchIndexChannel
        let matchExpression: String
        let highlightTerms: [String]
    }

    struct Variant: Sendable {
        let canonicalPhrase: String
        let channel: Channel
    }

    let canonicalPhrase: String
    let tokens: [String]
    let primaryChannels: [Channel]
    let relaxedChannel: Channel?
}

nonisolated enum EpisodeSearchQueryCompiler {
    private static let maximumTokenCount = 12
    private static let maximumQueryCharacterCount = 512

    static func compile(
        _ query: String,
        mode: EpisodeSearchMode
    ) -> EpisodeSearchCompiledQuery? {
        let boundedQuery = String(query.prefix(maximumQueryCharacterCount))
        let allTokens = SearchTextNormalization.uniqueSearchTokens(
            in: boundedQuery
        )
        let tokens = Array(allTokens.prefix(maximumTokenCount))
        guard !tokens.isEmpty else {
            return nil
        }
        let fields = searchableFields(
            mode: mode,
            canonicalQuery: tokens.joined(separator: " ")
        )
        return compile(
            boundedQuery,
            allTokens: allTokens,
            fields: fields
        )
    }

    static func compileTranscript(
        _ query: String
    ) -> EpisodeSearchCompiledQuery? {
        let boundedQuery = String(query.prefix(maximumQueryCharacterCount))
        let allTokens = SearchTextNormalization.uniqueSearchTokens(
            in: boundedQuery
        )
        let tokens = Array(allTokens.prefix(maximumTokenCount))
        guard !tokens.isEmpty,
              tokens.joined(separator: " ").count >= 3
        else {
            return nil
        }
        return compile(
            boundedQuery,
            allTokens: allTokens,
            fields: "text"
        )
    }

    private static func compile(
        _ query: String,
        allTokens: [String],
        fields: String
    ) -> EpisodeSearchCompiledQuery {
        let tokens = Array(allTokens.prefix(maximumTokenCount))
        let exactTerms = tokens.map(quotedLiteral)
        let exactExpression = scopedExpression(
            fields: fields,
            terms: exactTerms,
            joiner: " AND "
        )
        var primaryChannels = [
            EpisodeSearchCompiledQuery.Channel(
                kind: .exact,
                matchExpression: exactExpression,
                highlightTerms: tokens
            )
        ]

        if tokens.count == allTokens.count,
           isIncrementalPrefixQuery(query),
           let finalToken = tokens.last,
           finalToken.count >= 2 {
            var prefixTerms = exactTerms
            prefixTerms[prefixTerms.index(before: prefixTerms.endIndex)] =
                "\(quotedLiteral(finalToken))*"
            let prefixExpression = scopedExpression(
                fields: fields,
                terms: prefixTerms,
                joiner: " AND "
            )
            if prefixExpression != exactExpression {
                primaryChannels.append(
                    EpisodeSearchCompiledQuery.Channel(
                        kind: .prefix,
                        matchExpression: prefixExpression,
                        highlightTerms: tokens
                    )
                )
            }
        }

        let relaxedChannel: EpisodeSearchCompiledQuery.Channel? = if tokens.count >= 2 {
            EpisodeSearchCompiledQuery.Channel(
                kind: .relaxed,
                matchExpression: relaxedExpression(
                    fields: fields,
                    terms: exactTerms
                ),
                highlightTerms: tokens
            )
        } else {
            nil
        }

        return EpisodeSearchCompiledQuery(
            canonicalPhrase: tokens.joined(separator: " "),
            tokens: tokens,
            primaryChannels: primaryChannels,
            relaxedChannel: relaxedChannel
        )
    }

    static func correctedVariant(
        tokens: [String],
        mode: EpisodeSearchMode
    ) -> EpisodeSearchCompiledQuery.Variant? {
        correctedVariant(
            tokens: tokens,
            fields: searchableFields(
                mode: mode,
                canonicalQuery: tokens.joined(separator: " ")
            ),
            prefixesFinalTerm: false
        )
    }

    static func correctedPrefixVariant(
        tokens: [String],
        mode: EpisodeSearchMode
    ) -> EpisodeSearchCompiledQuery.Variant? {
        correctedVariant(
            tokens: tokens,
            fields: searchableFields(
                mode: mode,
                canonicalQuery: tokens.joined(separator: " ")
            ),
            prefixesFinalTerm: true
        )
    }

    static func correctedTranscriptVariant(
        tokens: [String]
    ) -> EpisodeSearchCompiledQuery.Variant? {
        correctedVariant(
            tokens: tokens,
            fields: "text",
            prefixesFinalTerm: false
        )
    }

    static func correctedTranscriptPrefixVariant(
        tokens: [String]
    ) -> EpisodeSearchCompiledQuery.Variant? {
        correctedVariant(
            tokens: tokens,
            fields: "text",
            prefixesFinalTerm: true
        )
    }

    private static func correctedVariant(
        tokens: [String],
        fields: String,
        prefixesFinalTerm: Bool
    ) -> EpisodeSearchCompiledQuery.Variant? {
        var seen: Set<String> = []
        let normalizedTokens = tokens
            .flatMap(SearchTextNormalization.searchTokens(in:))
            .filter { seen.insert($0).inserted }
            .prefix(maximumTokenCount)
        guard !normalizedTokens.isEmpty else {
            return nil
        }

        let tokens = Array(normalizedTokens)
        let canonicalPhrase = tokens.joined(separator: " ")
        var terms = tokens.map(quotedLiteral)
        if prefixesFinalTerm,
           let finalToken = tokens.last,
           finalToken.count >= 2 {
            terms[terms.index(before: terms.endIndex)] =
                "\(quotedLiteral(finalToken))*"
        }
        return EpisodeSearchCompiledQuery.Variant(
            canonicalPhrase: canonicalPhrase,
            channel: EpisodeSearchCompiledQuery.Channel(
                kind: .corrected,
                matchExpression: scopedExpression(
                    fields: fields,
                    terms: terms,
                    joiner: " AND "
                ),
                highlightTerms: tokens
            )
        )
    }

    private static func scopedExpression(
        fields: String,
        terms: [String],
        joiner: String
    ) -> String {
        "\(fields) : (\(terms.joined(separator: joiner)))"
    }

    private static func relaxedExpression(
        fields: String,
        terms: [String]
    ) -> String {
        guard terms.count > 2 else {
            return scopedExpression(
                fields: fields,
                terms: terms,
                joiner: " OR "
            )
        }

        // FTS5 has no minimum-should-match operator. Requiring all but one
        // term retains a useful recall path without letting a single generic
        // token dominate a long query.
        let clauses = terms.indices.map { omittedIndex in
            let retainedTerms = terms.indices.compactMap { index in
                index == omittedIndex ? nil : terms[index]
            }
            return "(\(retainedTerms.joined(separator: " AND ")))"
        }
        return "\(fields) : (\(clauses.joined(separator: " OR ")))"
    }

    private static func searchableFields(
        mode: EpisodeSearchMode,
        canonicalQuery: String
    ) -> String {
        let searchesHiddenText = mode == .fullText
            && canonicalQuery.count >= 3
        return searchesHiddenText
            ? "{title podcast_title summary show_notes}"
            : "{title podcast_title}"
    }

    private static func quotedLiteral(_ token: String) -> String {
        "\"\(token.replacing("\"", with: "\"\""))\""
    }

    private static func isIncrementalPrefixQuery(_ query: String) -> Bool {
        guard let finalCharacter = query.last else {
            return false
        }
        return finalCharacter.isLetter || finalCharacter.isNumber
    }
}
