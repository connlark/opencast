import Foundation

/// Fetches and parses a merged result's candidate feeds and decides
/// whether to subscribe directly or present a choice. Parsed catalogs
/// drive every decision; provider counts and timestamps are hints only.
public struct DirectoryFeedCandidateResolver: Sendable {
    /// A material difference is at least this many episodes…
    public static let materialEpisodeGap = 10
    /// …and at least this fraction of the larger parsed catalog.
    public static let materialFractionOfLarger = 0.2
    /// A fuller feed is promoted only when its newest parsed episode is
    /// no more than this much older than the other candidate's newest.
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
            // Every candidate failed: surface the primary candidate's error.
            throw firstError(in: outcomes) ?? OpenCastCoreError.invalidHTTPResponse
        }

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
        let larger = max(first, second)
        guard larger > 0 else {
            return false
        }
        return gap >= materialEpisodeGap
            && Double(gap) >= materialFractionOfLarger * Double(larger)
    }

    /// The staleness guard: an alternate with no parsed dates never
    /// promotes; otherwise its newest episode must be within tolerance
    /// of the primary's newest.
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
        return alternateNewest >= primaryNewest.addingTimeInterval(-stalenessTolerance)
    }

    private func hasConflictingGUID(
        _ first: ResolvedFeedCandidate,
        _ second: ResolvedFeedCandidate
    ) -> Bool {
        guard let firstGUID = normalizedGUID(first.snapshot.podcast.podcastGUID),
              let secondGUID = normalizedGUID(second.snapshot.podcast.podcastGUID)
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
                        let outcome = try await feedService.fetchFeedOutcome(at: candidate.feedURL)
                        guard let snapshot = outcome.snapshot else {
                            throw OpenCastCoreError.invalidHTTPResponse
                        }
                        let resolved = ResolvedFeedCandidate(
                            candidate: candidate,
                            snapshot: snapshot,
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
