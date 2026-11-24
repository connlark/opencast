import Foundation

public struct DirectoryFeedCandidateResolver: Sendable {
    /// One extra parsed item is material: it can expose a truncated directory feed.
    public static let materialEpisodeGap = 1
    public static let stalenessTolerance: TimeInterval = 30 * 24 * 60 * 60

    let feedService: any FeedService

    public init(feedService: any FeedService = DefaultFeedService()) {
        self.feedService = feedService
    }

    public func resolve(candidates: [DirectoryFeedCandidate]) async throws -> DirectoryFeedResolution {
        let uniqueCandidates = DirectoryResultMerger.mergedCandidates(candidates)
        guard !uniqueCandidates.isEmpty else {
            throw OpenCastCoreError.invalidFeedURL
        }

        let outcomes = await fetchAll(uniqueCandidates)
        try Task.checkCancellation()

        let resolved = outcomes.compactMap { outcome in
            try? outcome.get()
        }
        guard let primary = resolved.first else {
            throw firstError(in: outcomes) ?? OpenCastCoreError.invalidHTTPResponse
        }
        let readFeedURLs = Set(resolved.flatMap { [$0.candidate.canonicalFeedURLString, $0.canonicalResolvedURLString] })
        return DirectoryFeedResolution(outcome: outcome(primary: primary, resolved: resolved), readFeedURLs: readFeedURLs)
    }

    private func outcome(
        primary: ResolvedFeedCandidate,
        resolved: [ResolvedFeedCandidate]
    ) -> DirectoryFeedResolution.Outcome {
        let alternates = resolved.dropFirst().filter { alternate in
            alternate.canonicalResolvedURLString != primary.canonicalResolvedURLString
                && !hasConflictingGUID(primary, alternate)
        }
        guard let alternate = alternates.max(by: { $0.episodeCount < $1.episodeCount }) else {
            return .subscribe(primary)
        }

        guard Self.isMaterialDifference(primary.episodeCount, alternate.episodeCount),
              alternate.episodeCount > primary.episodeCount
        else {
            return .subscribe(primary)
        }

        if alternate.isSalvaged, !primary.isSalvaged {
            return .choice(
                DirectoryFeedChoice(primary: primary, secondary: alternate, reason: .fullerFeedSalvaged)
            )
        }
        if Self.isCurrent(alternate, relativeTo: primary) {
            return .choice(
                DirectoryFeedChoice(primary: alternate, secondary: primary, reason: .fullerFeedPromoted)
            )
        }
        return .choice(
            DirectoryFeedChoice(primary: primary, secondary: alternate, reason: .fullerFeedStale)
        )
    }

    public static func isMaterialDifference(_ first: Int, _ second: Int) -> Bool {
        let gap = abs(first - second)
        return gap >= materialEpisodeGap
    }

    static func isCurrent(
        _ alternate: ResolvedFeedCandidate,
        relativeTo primary: ResolvedFeedCandidate
    ) -> Bool {
        guard let alternateNewest = alternate.newestEpisodeDate else {
            return false
        }
        guard let primaryNewest = primary.newestEpisodeDate else {
            return true
        }
        return alternateNewest.timeIntervalSinceReferenceDate
            >= primaryNewest.addingTimeInterval(-stalenessTolerance).timeIntervalSinceReferenceDate
    }

    private func hasConflictingGUID(
        _ first: ResolvedFeedCandidate,
        _ second: ResolvedFeedCandidate
    ) -> Bool {
        guard let firstGUID = normalizedGUID(first.podcast.podcastGUID),
              let secondGUID = normalizedGUID(second.podcast.podcastGUID)
        else {
            return false
        }
        return firstGUID != secondGUID
    }

    private func normalizedGUID(_ guid: String?) -> String? {
        guard let value = guid?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty
        else {
            return nil
        }
        return value
    }

    private func fetchAll(
        _ candidates: [DirectoryFeedCandidate]
    ) async -> [Result<ResolvedFeedCandidate, any Error>] {
        let feedService = feedService
        return await withTaskGroup(
            of: (Int, Result<ResolvedFeedCandidate, any Error>).self
        ) { group in
            for (index, candidate) in candidates.enumerated() {
                group.addTask {
                    do {
                        let outcome = try await feedService.prepareFeed(
                            at: candidate.feedURL,
                            validators: nil,
                            intent: .interactive
                        )
                        guard let snapshot = outcome.feed else {
                            throw OpenCastCoreError.invalidHTTPResponse
                        }
                        let resolved = ResolvedFeedCandidate(
                            candidate: candidate,
                            prepared: snapshot,
                            finalURL: outcome.finalURL
                        )
                        return (index, .success(resolved))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }

            var outcomes = [Result<ResolvedFeedCandidate, any Error>?](
                repeating: nil,
                count: candidates.count
            )
            for await (index, outcome) in group {
                outcomes[index] = outcome
            }
            return outcomes.compactMap { $0 }
        }
    }

    private func firstError(in outcomes: [Result<ResolvedFeedCandidate, any Error>]) -> (any Error)? {
        for outcome in outcomes {
            if case .failure(let error) = outcome {
                return error
            }
        }
        return nil
    }
}
