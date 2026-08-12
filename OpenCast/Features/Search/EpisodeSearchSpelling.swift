import Foundation

nonisolated struct EpisodeSearchVocabularyField: OptionSet, Sendable {
    let rawValue: Int

    static let title = Self(rawValue: 1 << 0)
    static let podcastTitle = Self(rawValue: 1 << 1)
    static let body = Self(rawValue: 1 << 2)
    static let transcript = Self(rawValue: 1 << 3)
}

nonisolated struct EpisodeSearchVocabularyContribution: Sendable {
    let term: String
    let fields: EpisodeSearchVocabularyField
    let occurrenceCount: Int
}

nonisolated struct EpisodeSearchCorrectionCandidate: Sendable {
    let term: String
    let titleDocumentCount: Int
    let podcastTitleDocumentCount: Int
    let bodyDocumentCount: Int
    let transcriptDocumentCount: Int
    let documentCount: Int
    let occurrenceCount: Int
}

nonisolated enum EpisodeSearchSpelling {
    static let minimumTermLength = 5
    static let maximumTermLength = 32
    static let maximumCorrectedTermCount = 2
    static let candidateLimit = 128
    static let minimumMorphologicalPrefixLength = 6

    static func isEligibleTerm(_ term: String) -> Bool {
        (minimumTermLength ... maximumTermLength).contains(term.count)
            && term.contains(where: \Character.isLetter)
    }

    static func contributions(
        _ fields: [(String, EpisodeSearchVocabularyField)]
    ) -> [EpisodeSearchVocabularyContribution] {
        struct Accumulator {
            var fields: EpisodeSearchVocabularyField = []
            var occurrenceCount = 0
        }

        var valuesByTerm: [String: Accumulator] = [:]
        for (text, field) in fields {
            for term in SearchTextNormalization.searchTokens(in: text)
            where isEligibleTerm(term) {
                valuesByTerm[term, default: Accumulator()].fields.formUnion(field)
                valuesByTerm[term, default: Accumulator()].occurrenceCount += 1
            }
        }
        return valuesByTerm.map { term, value in
            EpisodeSearchVocabularyContribution(
                term: term,
                fields: value.fields,
                occurrenceCount: value.occurrenceCount
            )
        }
        .sorted { $0.term < $1.term }
    }

    static func deletionKeys(for term: String) -> [String] {
        guard isEligibleTerm(term) else {
            return []
        }
        var values: Set<String> = [term]
        for index in term.indices {
            var candidate = term
            candidate.remove(at: index)
            values.insert(candidate)
        }
        if term.count >= minimumMorphologicalPrefixLength + 2 {
            values.insert(
                "^\(term.prefix(minimumMorphologicalPrefixLength))"
            )
        }
        return values.sorted()
    }

    static func bestCandidate(
        for observed: String,
        from candidates: [EpisodeSearchCorrectionCandidate]
    ) -> EpisodeSearchCorrectionCandidate? {
        guard isEligibleTerm(observed) else {
            return nil
        }
        let directCandidates = candidates
            .filter { $0.term != observed && isWithinOneEdit(observed, $0.term) }
            .sorted(by: isOrderedBefore)
        if let best = bestUnambiguousCandidate(from: directCandidates) {
            return best
        }
        let inflectionalCandidates = expandedInflectionalCandidates(candidates)
            .filter { $0.term != observed && isWithinOneEdit(observed, $0.term) }
            .sorted(by: isOrderedBefore)
        return bestUnambiguousCandidate(from: inflectionalCandidates)
    }

    static func bestMorphologicalCandidate(
        for observed: String,
        from candidates: [EpisodeSearchCorrectionCandidate]
    ) -> EpisodeSearchCorrectionCandidate? {
        guard observed.count >= minimumMorphologicalPrefixLength + 2 else {
            return nil
        }
        let viable = expandedInflectionalCandidates(candidates)
            .filter { candidate in
                guard candidate.term != observed,
                      candidate.term.count >= minimumMorphologicalPrefixLength + 2
                else {
                    return false
                }
                let sharedPrefixLength = zip(observed, candidate.term)
                    .prefix { pair in pair.0 == pair.1 }
                    .count
                return sharedPrefixLength >= minimumMorphologicalPrefixLength
                    && sharedPrefixLength
                        >= min(observed.count, candidate.term.count) - 2
            }
            .sorted(by: isOrderedBefore)
        guard viable.count == 1, let best = viable.first else {
            return nil
        }
        return best
    }

    static func isWithinOneEdit(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs)
        let right = Array(rhs)
        let lengthDelta = left.count - right.count
        guard abs(lengthDelta) <= 1 else {
            return false
        }
        if lengthDelta == 0 {
            let mismatches = left.indices.filter { left[$0] != right[$0] }
            switch mismatches.count {
            case 0, 1:
                return true
            case 2:
                let first = mismatches[0]
                let second = mismatches[1]
                return second == first + 1
                    && left[first] == right[second]
                    && left[second] == right[first]
            default:
                return false
            }
        }

        let shorter = lengthDelta < 0 ? left : right
        let longer = lengthDelta < 0 ? right : left
        var shortIndex = 0
        var longIndex = 0
        var skipped = false
        while shortIndex < shorter.count, longIndex < longer.count {
            if shorter[shortIndex] == longer[longIndex] {
                shortIndex += 1
                longIndex += 1
            } else if skipped {
                return false
            } else {
                skipped = true
                longIndex += 1
            }
        }
        return true
    }

    private static func expandedInflectionalCandidates(
        _ candidates: [EpisodeSearchCorrectionCandidate]
    ) -> [EpisodeSearchCorrectionCandidate] {
        var valuesByTerm: [String: EpisodeSearchCorrectionCandidate] = [:]
        for candidate in candidates {
            valuesByTerm[candidate.term] = candidate
            guard candidate.term.count >= minimumTermLength + 1,
                  candidate.term.hasSuffix("s"),
                  !candidate.term.hasSuffix("ss")
            else {
                continue
            }
            let singularTerm = String(candidate.term.dropLast())
            valuesByTerm[singularTerm] = candidate.withTerm(singularTerm)
        }
        return Array(valuesByTerm.values)
    }

    private static func bestUnambiguousCandidate(
        from candidates: [EpisodeSearchCorrectionCandidate]
    ) -> EpisodeSearchCorrectionCandidate? {
        guard let best = candidates.first else {
            return nil
        }
        if candidates.count > 1,
           hasEqualConfidence(best, candidates[1]) {
            return nil
        }
        return best
    }

    private static func isOrderedBefore(
        _ lhs: EpisodeSearchCorrectionCandidate,
        _ rhs: EpisodeSearchCorrectionCandidate
    ) -> Bool {
        let lhsValues = rankingValues(lhs)
        let rhsValues = rankingValues(rhs)
        for (lhsValue, rhsValue) in zip(lhsValues, rhsValues)
        where lhsValue != rhsValue {
            return lhsValue > rhsValue
        }
        return lhs.term < rhs.term
    }

    private static func hasEqualConfidence(
        _ lhs: EpisodeSearchCorrectionCandidate,
        _ rhs: EpisodeSearchCorrectionCandidate
    ) -> Bool {
        rankingValues(lhs) == rankingValues(rhs)
    }

    private static func rankingValues(
        _ candidate: EpisodeSearchCorrectionCandidate
    ) -> [Int] {
        [
            candidate.titleDocumentCount > 0 ? 1 : 0,
            candidate.podcastTitleDocumentCount > 0 ? 1 : 0,
            candidate.transcriptDocumentCount > 0 ? 1 : 0,
            candidate.bodyDocumentCount > 0 ? 1 : 0,
            candidate.titleDocumentCount,
            candidate.podcastTitleDocumentCount,
            candidate.transcriptDocumentCount,
            candidate.bodyDocumentCount,
            candidate.documentCount,
            candidate.occurrenceCount,
        ]
    }
}

nonisolated private extension EpisodeSearchCorrectionCandidate {
    func withTerm(_ term: String) -> Self {
        Self(
            term: term,
            titleDocumentCount: titleDocumentCount,
            podcastTitleDocumentCount: podcastTitleDocumentCount,
            bodyDocumentCount: bodyDocumentCount,
            transcriptDocumentCount: transcriptDocumentCount,
            documentCount: documentCount,
            occurrenceCount: occurrenceCount
        )
    }
}
