import Foundation
import SwiftUI

enum EpisodeSearch {
    private nonisolated static let comparisonOptions: String.CompareOptions = [
        .caseInsensitive,
        .diacriticInsensitive,
        .widthInsensitive
    ]
    private nonisolated static let snippetTargetLength = 160

    static func isSearchActive(query: String) -> Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func documents(from episodes: [EpisodeCacheRecord]) -> [EpisodeSearchDocument] {
        episodes.enumerated().map { index, episode in
            EpisodeSearchDocument(
                episodeID: episode.episodeID,
                sourceIndex: index,
                title: episode.title,
                podcastTitle: episode.podcastTitle,
                summaryHTML: episode.summary,
                showNotesHTML: episode.showNotesHTML
            )
        }
    }

    static func results(
        in episodes: [EpisodeCacheRecord],
        query: String,
        mode: EpisodeSearchMode
    ) -> [EpisodeSearchResult] {
        guard isSearchActive(query: query) else {
            return episodes.map(unfilteredResult)
        }

        let matches = matchesSynchronously(
            in: documents(from: episodes),
            query: query,
            mode: mode,
            shouldStop: { false }
        )
        let episodesByID = Dictionary(
            episodes.map { ($0.episodeID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return results(from: matches, episodesByID: episodesByID)
    }

    @concurrent
    static func matches(
        in documents: [EpisodeSearchDocument],
        query: String,
        mode: EpisodeSearchMode
    ) async -> [EpisodeSearchMatch] {
        matchesSynchronously(
            in: documents,
            query: query,
            mode: mode,
            shouldStop: { Task.isCancelled }
        )
    }

    static func results(
        from matches: [EpisodeSearchMatch],
        episodesByID: [String: EpisodeCacheRecord]
    ) -> [EpisodeSearchResult] {
        matches.compactMap { match in
            guard let episode = episodesByID[match.episodeID] else {
                return nil
            }

            return result(for: episode, match: match)
        }
    }

    private nonisolated static func matchesSynchronously(
        in documents: [EpisodeSearchDocument],
        query: String,
        mode: EpisodeSearchMode,
        shouldStop: () -> Bool
    ) -> [EpisodeSearchMatch] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let queryTokens = uniqueTerms(searchTokens(in: trimmedQuery))
        guard !queryTokens.isEmpty else {
            return []
        }

        switch mode {
        case .episodes:
            return documents.compactMap { document in
                guard !shouldStop() else {
                    return nil
                }

                return exactVisibleMatch(for: document, queryTokens: queryTokens)
            }
        case .fullText:
            guard trimmedQuery.count >= 3 else {
                return documents.compactMap { document in
                    guard !shouldStop() else {
                        return nil
                    }

                    return exactVisibleMatch(for: document, queryTokens: queryTokens)
                }
            }

            return documents
                .compactMap { document -> EpisodeSearchMatch? in
                    guard !shouldStop() else {
                        return nil
                    }

                    return fullTextMatch(for: document, queryTokens: queryTokens)
                }
                .sorted {
                    $0.rank.rawValue == $1.rank.rawValue
                        ? $0.sourceIndex < $1.sourceIndex
                        : $0.rank.rawValue < $1.rank.rawValue
                }
        }
    }

    private nonisolated static func exactVisibleMatch(
        for document: EpisodeSearchDocument,
        queryTokens: [String]
    ) -> EpisodeSearchMatch? {
        let titleMatch = exactFieldMatch(in: document.title, queryTokens: queryTokens)
        let podcastTitleMatch = exactFieldMatch(in: document.podcastTitle, queryTokens: queryTokens)
        guard satisfiesAll(queryTokens, with: [titleMatch.satisfiedTokens, podcastTitleMatch.satisfiedTokens]) else {
            return nil
        }

        return EpisodeSearchMatch(
            episodeID: document.episodeID,
            sourceIndex: document.sourceIndex,
            rank: .exactVisible,
            titleTerms: titleMatch.highlightTerms,
            podcastTitleTerms: podcastTitleMatch.highlightTerms,
            summaryTerms: [],
            showNotesTerms: []
        )
    }

    private nonisolated static func fullTextMatch(
        for document: EpisodeSearchDocument,
        queryTokens: [String]
    ) -> EpisodeSearchMatch? {
        let titleMatch = exactFieldMatch(in: document.title, queryTokens: queryTokens)
        let podcastTitleMatch = exactFieldMatch(in: document.podcastTitle, queryTokens: queryTokens)
        let visibleSatisfiedTokens = [titleMatch.satisfiedTokens, podcastTitleMatch.satisfiedTokens]
        if satisfiesAll(queryTokens, with: visibleSatisfiedTokens) {
            return match(
                for: document,
                rank: .exactVisible,
                titleTerms: titleMatch.highlightTerms,
                podcastTitleTerms: podcastTitleMatch.highlightTerms
            )
        }

        let summaryText = plainText(document.summaryHTML)
        let summaryMatch = exactFieldMatch(in: summaryText, queryTokens: queryTokens)
        if satisfiesAll(queryTokens, with: visibleSatisfiedTokens + [summaryMatch.satisfiedTokens]) {
            return match(
                for: document,
                rank: .exactSummary,
                titleTerms: titleMatch.highlightTerms,
                podcastTitleTerms: podcastTitleMatch.highlightTerms,
                summaryTerms: summaryMatch.highlightTerms
            )
        }

        let showNotesText = plainText(document.showNotesHTML)
        let showNotesMatch = exactFieldMatch(in: showNotesText, queryTokens: queryTokens)
        if satisfiesAll(
            queryTokens,
            with: visibleSatisfiedTokens + [summaryMatch.satisfiedTokens, showNotesMatch.satisfiedTokens]
        ) {
            return match(
                for: document,
                rank: .exactShowNotes,
                titleTerms: titleMatch.highlightTerms,
                podcastTitleTerms: podcastTitleMatch.highlightTerms,
                summaryTerms: summaryMatch.highlightTerms,
                showNotesTerms: showNotesMatch.highlightTerms
            )
        }

        let fuzzyTitleMatch = fuzzyFieldMatch(in: document.title, queryTokens: queryTokens)
        let fuzzyPodcastTitleMatch = fuzzyFieldMatch(in: document.podcastTitle, queryTokens: queryTokens)
        let fuzzyVisibleSatisfiedTokens = [fuzzyTitleMatch.satisfiedTokens, fuzzyPodcastTitleMatch.satisfiedTokens]
        if satisfiesAll(queryTokens, with: fuzzyVisibleSatisfiedTokens) {
            return match(
                for: document,
                rank: .fuzzyVisible,
                titleTerms: fuzzyTitleMatch.highlightTerms,
                podcastTitleTerms: fuzzyPodcastTitleMatch.highlightTerms
            )
        }

        let fuzzySummaryMatch = fuzzyFieldMatch(in: summaryText, queryTokens: queryTokens)
        if satisfiesAll(queryTokens, with: fuzzyVisibleSatisfiedTokens + [fuzzySummaryMatch.satisfiedTokens]) {
            return match(
                for: document,
                rank: .fuzzySummary,
                titleTerms: fuzzyTitleMatch.highlightTerms,
                podcastTitleTerms: fuzzyPodcastTitleMatch.highlightTerms,
                summaryTerms: fuzzySummaryMatch.highlightTerms
            )
        }

        let fuzzyShowNotesMatch = fuzzyFieldMatch(in: showNotesText, queryTokens: queryTokens)
        guard satisfiesAll(
            queryTokens,
            with: fuzzyVisibleSatisfiedTokens + [fuzzySummaryMatch.satisfiedTokens, fuzzyShowNotesMatch.satisfiedTokens]
        ) else {
            return nil
        }

        return match(
            for: document,
            rank: .fuzzyShowNotes,
            titleTerms: fuzzyTitleMatch.highlightTerms,
            podcastTitleTerms: fuzzyPodcastTitleMatch.highlightTerms,
            summaryTerms: fuzzySummaryMatch.highlightTerms,
            showNotesTerms: fuzzyShowNotesMatch.highlightTerms
        )
    }

    private nonisolated static func match(
        for document: EpisodeSearchDocument,
        rank: EpisodeSearchRank,
        titleTerms: [String],
        podcastTitleTerms: [String],
        summaryTerms: [String] = [],
        showNotesTerms: [String] = []
    ) -> EpisodeSearchMatch {
        EpisodeSearchMatch(
            episodeID: document.episodeID,
            sourceIndex: document.sourceIndex,
            rank: rank,
            titleTerms: titleTerms,
            podcastTitleTerms: podcastTitleTerms,
            summaryTerms: summaryTerms,
            showNotesTerms: showNotesTerms
        )
    }

    private static func result(
        for episode: EpisodeCacheRecord,
        match: EpisodeSearchMatch
    ) -> EpisodeSearchResult {
        EpisodeSearchResult(
            episode: episode,
            highlightedTitle: highlightedText(episode.title, terms: match.titleTerms),
            highlightedPodcastTitle: highlightedText(
                episode.podcastTitle,
                terms: match.podcastTitleTerms,
                baseForegroundColor: .secondary
            ),
            snippet: match.rank.usesHiddenText ? snippet(for: episode, match: match) : nil
        )
    }

    private static func unfilteredResult(for episode: EpisodeCacheRecord) -> EpisodeSearchResult {
        EpisodeSearchResult(
            episode: episode,
            highlightedTitle: AttributedString(episode.title),
            highlightedPodcastTitle: AttributedString(episode.podcastTitle),
            snippet: nil
        )
    }

    private static func snippet(
        for episode: EpisodeCacheRecord,
        match: EpisodeSearchMatch
    ) -> AttributedString? {
        let summaryText = plainText(episode.summary)
        if !summaryText.isEmpty, !match.summaryTerms.isEmpty {
            return highlightedText(
                snippetText(from: summaryText, terms: match.summaryTerms),
                terms: match.summaryTerms,
                baseForegroundColor: .secondary
            )
        }

        let showNotesText = plainText(episode.showNotesHTML)
        guard !showNotesText.isEmpty, !match.showNotesTerms.isEmpty else {
            return nil
        }

        return highlightedText(
            snippetText(from: showNotesText, terms: match.showNotesTerms),
            terms: match.showNotesTerms,
            baseForegroundColor: .secondary
        )
    }

    private static func highlightedText(
        _ text: String,
        terms: [String],
        baseForegroundColor: Color? = nil
    ) -> AttributedString {
        var attributed = AttributedString(text)
        if let baseForegroundColor {
            attributed.foregroundColor = baseForegroundColor
        }

        for term in uniqueTerms(terms) where !term.isEmpty {
            var searchRange = text.startIndex..<text.endIndex
            while let range = text.range(
                of: term,
                options: comparisonOptions,
                range: searchRange,
                locale: .current
            ) {
                if let attributedRange = Range(range, in: attributed) {
                    attributed[attributedRange].inlinePresentationIntent = .stronglyEmphasized
                    attributed[attributedRange].foregroundColor = .accentColor
                }
                searchRange = range.upperBound..<text.endIndex
            }
        }

        return attributed
    }

    private nonisolated static func exactFieldMatch(
        in text: String,
        queryTokens: [String]
    ) -> (highlightTerms: [String], satisfiedTokens: Set<String>) {
        var highlightTerms: [String] = []
        var satisfiedTokens: Set<String> = []

        for queryToken in queryTokens where containsExactTerm(queryToken, in: text) {
            highlightTerms.append(queryToken)
            satisfiedTokens.insert(normalized(queryToken))
        }

        return (uniqueTerms(highlightTerms), satisfiedTokens)
    }

    private nonisolated static func fuzzyFieldMatch(
        in text: String,
        queryTokens: [String]
    ) -> (highlightTerms: [String], satisfiedTokens: Set<String>) {
        let fieldTokens = searchTokens(in: text)
        var highlightTerms: [String] = []
        var satisfiedTokens: Set<String> = []

        for queryToken in queryTokens {
            if containsExactTerm(queryToken, in: text) {
                highlightTerms.append(queryToken)
                satisfiedTokens.insert(normalized(queryToken))
                continue
            }

            let matchedTerms = fieldTokens.filter { isFuzzyMatch(queryToken: queryToken, fieldToken: $0) }
            if !matchedTerms.isEmpty {
                highlightTerms.append(contentsOf: matchedTerms)
                satisfiedTokens.insert(normalized(queryToken))
            }
        }

        return (uniqueTerms(highlightTerms), satisfiedTokens)
    }

    private nonisolated static func satisfiesAll(
        _ queryTokens: [String],
        with fieldSatisfiedTokens: [Set<String>]
    ) -> Bool {
        let satisfiedTokens = fieldSatisfiedTokens.reduce(into: Set<String>()) { partialResult, tokens in
            partialResult.formUnion(tokens)
        }
        return queryTokens.allSatisfy { satisfiedTokens.contains(normalized($0)) }
    }

    private nonisolated static func containsExactTerm(_ term: String, in text: String) -> Bool {
        text.range(of: term, options: comparisonOptions, locale: .current) != nil
    }

    private nonisolated static func isFuzzyMatch(queryToken: String, fieldToken: String) -> Bool {
        let normalizedQuery = normalized(queryToken)
        let normalizedField = normalized(fieldToken)
        guard normalizedQuery != normalizedField,
              let limit = editDistanceLimit(for: normalizedQuery),
              abs(normalizedQuery.count - normalizedField.count) <= limit
        else {
            return false
        }

        return editDistance(normalizedQuery, normalizedField, maximum: limit) != nil
    }

    private nonisolated static func editDistanceLimit(for token: String) -> Int? {
        switch token.count {
        case 3...5:
            1
        case 6...:
            2
        default:
            nil
        }
    }

    private nonisolated static func editDistance(_ lhs: String, _ rhs: String, maximum: Int) -> Int? {
        let lhsCharacters = Array(lhs)
        let rhsCharacters = Array(rhs)
        guard abs(lhsCharacters.count - rhsCharacters.count) <= maximum else {
            return nil
        }

        var previousRow = Array(0...rhsCharacters.count)
        for lhsIndex in lhsCharacters.indices {
            var currentRow = [lhsIndex + 1]
            var rowMinimum = currentRow[0]
            for rhsIndex in rhsCharacters.indices {
                let insertion = currentRow[rhsIndex] + 1
                let deletion = previousRow[rhsIndex + 1] + 1
                let substitution = previousRow[rhsIndex] + (lhsCharacters[lhsIndex] == rhsCharacters[rhsIndex] ? 0 : 1)
                let value = min(insertion, deletion, substitution)
                currentRow.append(value)
                rowMinimum = min(rowMinimum, value)
            }
            if rowMinimum > maximum {
                return nil
            }
            previousRow = currentRow
        }

        return previousRow[rhsCharacters.count] <= maximum ? previousRow[rhsCharacters.count] : nil
    }

    private static func snippetText(from text: String, terms: [String]) -> String {
        let cleanText = collapsedWhitespace(text)
        guard cleanText.count > snippetTargetLength,
              let firstMatch = firstRange(in: cleanText, terms: terms)
        else {
            return cleanText
        }

        let matchOffset = cleanText.distance(from: cleanText.startIndex, to: firstMatch.lowerBound)
        var startOffset = max(0, matchOffset - 60)
        let endOffset = min(cleanText.count, startOffset + snippetTargetLength)
        if endOffset == cleanText.count {
            startOffset = max(0, endOffset - snippetTargetLength)
        }

        var startIndex = cleanText.index(cleanText.startIndex, offsetBy: startOffset)
        var endIndex = cleanText.index(cleanText.startIndex, offsetBy: endOffset)
        if startIndex > cleanText.startIndex,
           let boundary = cleanText[startIndex...].firstIndex(where: \.isWhitespace) {
            startIndex = cleanText.index(after: boundary)
        }
        if endIndex < cleanText.endIndex,
           let boundary = cleanText[..<endIndex].lastIndex(where: \.isWhitespace) {
            endIndex = boundary
        }

        let prefix = startIndex > cleanText.startIndex ? "... " : ""
        let suffix = endIndex < cleanText.endIndex ? " ..." : ""
        let excerpt = cleanText[startIndex..<endIndex]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(prefix)\(excerpt)\(suffix)"
    }

    private static func firstRange(in text: String, terms: [String]) -> Range<String.Index>? {
        uniqueTerms(terms)
            .compactMap {
                text.range(of: $0, options: comparisonOptions, locale: .current)
            }
            .min { $0.lowerBound < $1.lowerBound }
    }

    private nonisolated static func plainText(_ text: String?) -> String {
        guard let text else {
            return ""
        }

        return collapsedWhitespace(text.plainTextFromHTML)
    }

    private nonisolated static func collapsedWhitespace(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private nonisolated static func searchTokens(in text: String) -> [String] {
        text.split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    private nonisolated static func uniqueTerms(_ terms: [String]) -> [String] {
        var seenTerms: Set<String> = []
        return terms.filter { term in
            let normalizedTerm = normalized(term)
            guard !normalizedTerm.isEmpty, !seenTerms.contains(normalizedTerm) else {
                return false
            }

            seenTerms.insert(normalizedTerm)
            return true
        }
    }

    private nonisolated static func normalized(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased(with: .current)
    }
}
