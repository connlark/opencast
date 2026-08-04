import Foundation
import OpenCastCore

/// Matches departed cache rows (episode IDs the feed no longer mints) onto
/// their re-identified successors by identity material, tiered: guid →
/// canonical audio URL → title+date → unambiguous title alone. A tier only
/// pairs a key that maps to exactly one departed row and exactly one
/// successor; ambiguous keys fall through to later tiers, and rows that never
/// match are retained as off-feed back-catalog.
nonisolated enum EpisodeIdentityReconciler {
    struct Candidate: Equatable, Sendable {
        let episodeID: String
        let guid: String?
        let audioURL: String?
        let title: String
        let publishedAt: Date?

        init(
            episodeID: String,
            guid: String?,
            audioURL: String?,
            title: String,
            publishedAt: Date?
        ) {
            self.episodeID = episodeID
            self.guid = guid
            self.audioURL = audioURL
            self.title = title
            self.publishedAt = publishedAt
        }

        init(episode: Episode) {
            self.init(
                episodeID: episode.id.rawValue,
                guid: episode.guid,
                audioURL: episode.audioURL?.absoluteString,
                title: episode.title,
                publishedAt: episode.publishedAt
            )
        }

        init(listItem: EpisodeListItemSnapshot) {
            self.init(
                episodeID: listItem.episodeID,
                guid: listItem.guid,
                audioURL: listItem.audioURL,
                title: listItem.title,
                publishedAt: listItem.publishedAt
            )
        }
    }

    struct Match: Equatable, Sendable {
        let departedEpisodeID: String
        let successorEpisodeID: String
    }

    static func matches(departed: [Candidate], successors: [Candidate]) -> [Match] {
        var departedPool = departed
        var successorPool = successors
        var matches: [Match] = []

        let tiers: [(Candidate) -> String?] = [
            { candidate in
                candidate.guid?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            },
            { candidate in
                candidate.audioURL.map(URLCanonicalizer.canonicalString(forRawString:))
            },
            { candidate in
                candidate.publishedAt.map { publishedAt in
                    "\(EpisodeIdentity.normalizedTitle(candidate.title))|\(Int(publishedAt.timeIntervalSince1970))"
                }
            },
            { candidate in
                EpisodeIdentity.normalizedTitle(candidate.title).nilIfEmpty
            }
        ]

        for tier in tiers {
            matchTier(
                departed: &departedPool,
                successors: &successorPool,
                matches: &matches,
                key: tier
            )
        }

        return matches
    }

    private static func matchTier(
        departed: inout [Candidate],
        successors: inout [Candidate],
        matches: inout [Match],
        key: (Candidate) -> String?
    ) {
        guard !departed.isEmpty, !successors.isEmpty else {
            return
        }

        let departedByKey = candidateCountsByKey(departed, key: key)
        let successorsByKey = candidateCountsByKey(successors, key: key)

        var matchedDepartedIDs = Set<String>()
        var matchedSuccessorIDs = Set<String>()
        for (tierKey, departedGroup) in departedByKey where departedGroup.count == 1 {
            guard let successorGroup = successorsByKey[tierKey], successorGroup.count == 1 else {
                continue
            }
            matches.append(
                Match(
                    departedEpisodeID: departedGroup[0].episodeID,
                    successorEpisodeID: successorGroup[0].episodeID
                )
            )
            matchedDepartedIDs.insert(departedGroup[0].episodeID)
            matchedSuccessorIDs.insert(successorGroup[0].episodeID)
        }

        departed.removeAll { matchedDepartedIDs.contains($0.episodeID) }
        successors.removeAll { matchedSuccessorIDs.contains($0.episodeID) }
    }

    private static func candidateCountsByKey(
        _ candidates: [Candidate],
        key: (Candidate) -> String?
    ) -> [String: [Candidate]] {
        var groups: [String: [Candidate]] = [:]
        for candidate in candidates {
            guard let candidateKey = key(candidate) else {
                continue
            }
            groups[candidateKey, default: []].append(candidate)
        }
        return groups
    }
}

nonisolated private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
