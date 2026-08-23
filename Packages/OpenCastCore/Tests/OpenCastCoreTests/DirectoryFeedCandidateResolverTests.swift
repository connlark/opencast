import Foundation
import OpenCastCore
import Testing

@Suite("Directory feed candidate resolver")
struct DirectoryFeedCandidateResolverTests {
    private static let newestEpisodeDate = Date(timeIntervalSince1970: 1_750_000_000)
    private let windowedURL = URL(string: "https://feeds.example.com/windowed")!
    private let fullURL = URL(string: "https://feeds.example.com/full")!

    @Test("Serial-shaped 33/124 candidates promote the fuller current feed")
    func serialShapedCandidatesPromoteFullerCurrentFeed() async throws {
        // Live counts measured 2026-08-22: the Apple feed served 33
        // items, the current full feed 124, same newest episode.
        let resolver = makeResolver([
            windowedURL: makeSnapshot(feedURL: windowedURL, episodeCount: 33, newest: Self.newestEpisodeDate),
            fullURL: makeSnapshot(feedURL: fullURL, episodeCount: 124, newest: Self.newestEpisodeDate),
        ])

        let resolution = try await resolver.resolve(candidates: serialShapedCandidates())

        let choice = try #require(choiceCase(from: resolution))
        #expect(choice.reason == .fullerFeedPromoted)
        #expect(choice.primary.candidate.feedURL == fullURL)
        #expect(choice.primary.episodeCount == 124)
        #expect(choice.primary.newestEpisodeDate == Self.newestEpisodeDate)
        #expect(choice.secondary.candidate.feedURL == windowedURL)
        #expect(choice.secondary.episodeCount == 33)
    }

    @Test("A fuller but stale feed stays secondary as an archive")
    func fullerButStaleFeedStaysSecondary() async throws {
        let staleNewest = Self.newestEpisodeDate.addingTimeInterval(-45 * 24 * 60 * 60)
        let resolver = makeResolver([
            windowedURL: makeSnapshot(feedURL: windowedURL, episodeCount: 33, newest: Self.newestEpisodeDate),
            fullURL: makeSnapshot(feedURL: fullURL, episodeCount: 124, newest: staleNewest),
        ])

        let resolution = try await resolver.resolve(candidates: serialShapedCandidates())

        let choice = try #require(choiceCase(from: resolution))
        #expect(choice.reason == .fullerFeedStale)
        #expect(choice.primary.candidate.feedURL == windowedURL)
        #expect(choice.secondary.candidate.feedURL == fullURL)
    }

    @Test("A fuller feed within the 30-day tolerance still promotes")
    func fullerFeedWithinToleranceStillPromotes() async throws {
        let slightlyOlder = Self.newestEpisodeDate.addingTimeInterval(-20 * 24 * 60 * 60)
        let resolver = makeResolver([
            windowedURL: makeSnapshot(feedURL: windowedURL, episodeCount: 33, newest: Self.newestEpisodeDate),
            fullURL: makeSnapshot(feedURL: fullURL, episodeCount: 124, newest: slightlyOlder),
        ])

        let resolution = try await resolver.resolve(candidates: serialShapedCandidates())

        let choice = try #require(choiceCase(from: resolution))
        #expect(choice.reason == .fullerFeedPromoted)
        #expect(choice.primary.candidate.feedURL == fullURL)
    }

    @Test("A salvaged fuller parse never outranks a clean feed")
    func salvagedFullerParseNeverOutranksCleanFeed() async throws {
        let resolver = makeResolver([
            windowedURL: makeSnapshot(feedURL: windowedURL, episodeCount: 33, newest: Self.newestEpisodeDate),
            fullURL: makeSnapshot(
                feedURL: fullURL,
                episodeCount: 124,
                newest: Self.newestEpisodeDate,
                isSalvaged: true
            ),
        ])

        let resolution = try await resolver.resolve(candidates: serialShapedCandidates())

        let choice = try #require(choiceCase(from: resolution))
        #expect(choice.reason == .fullerFeedSalvaged)
        #expect(choice.primary.candidate.feedURL == windowedURL)
        #expect(choice.secondary.isSalvaged)
    }

    @Test("Immaterial differences subscribe to the primary feed directly")
    func immaterialDifferenceSubscribesDirectly() async throws {
        let resolver = makeResolver([
            windowedURL: makeSnapshot(feedURL: windowedURL, episodeCount: 120, newest: Self.newestEpisodeDate),
            fullURL: makeSnapshot(feedURL: fullURL, episodeCount: 124, newest: Self.newestEpisodeDate),
        ])

        let resolution = try await resolver.resolve(candidates: serialShapedCandidates())

        let resolved = try #require(subscribedCase(from: resolution))
        #expect(resolved.candidate.feedURL == windowedURL)
    }

    @Test("A fuller primary feed subscribes directly without a prompt")
    func fullerPrimarySubscribesDirectly() async throws {
        let resolver = makeResolver([
            windowedURL: makeSnapshot(feedURL: windowedURL, episodeCount: 124, newest: Self.newestEpisodeDate),
            fullURL: makeSnapshot(feedURL: fullURL, episodeCount: 33, newest: Self.newestEpisodeDate),
        ])

        let resolution = try await resolver.resolve(candidates: serialShapedCandidates())

        let resolved = try #require(subscribedCase(from: resolution))
        #expect(resolved.candidate.feedURL == windowedURL)
    }

    @Test("Conflicting nonempty podcast GUIDs reject the alternate")
    func conflictingGUIDsRejectAlternate() async throws {
        let resolver = makeResolver([
            windowedURL: makeSnapshot(
                feedURL: windowedURL,
                episodeCount: 33,
                newest: Self.newestEpisodeDate,
                podcastGUID: "guid-one"
            ),
            fullURL: makeSnapshot(
                feedURL: fullURL,
                episodeCount: 124,
                newest: Self.newestEpisodeDate,
                podcastGUID: "guid-two"
            ),
        ])

        let resolution = try await resolver.resolve(candidates: serialShapedCandidates())

        let resolved = try #require(subscribedCase(from: resolution))
        #expect(resolved.candidate.feedURL == windowedURL)
    }

    @Test("Candidates resolving to the same final feed subscribe directly")
    func sameFinalFeedSubscribesDirectly() async throws {
        let resolver = makeResolver(
            [
                windowedURL: makeSnapshot(feedURL: windowedURL, episodeCount: 124, newest: Self.newestEpisodeDate),
                fullURL: makeSnapshot(feedURL: fullURL, episodeCount: 124, newest: Self.newestEpisodeDate),
            ],
            finalURLs: [windowedURL: fullURL]
        )

        let resolution = try await resolver.resolve(candidates: serialShapedCandidates())

        let resolved = try #require(subscribedCase(from: resolution))
        #expect(resolved.candidate.feedURL == windowedURL)
    }

    @Test("Only one working candidate subscribes directly")
    func singleWorkingCandidateSubscribesDirectly() async throws {
        let resolver = makeResolver([
            fullURL: makeSnapshot(feedURL: fullURL, episodeCount: 124, newest: Self.newestEpisodeDate)
        ])

        let resolution = try await resolver.resolve(candidates: serialShapedCandidates())

        let resolved = try #require(subscribedCase(from: resolution))
        #expect(resolved.candidate.feedURL == fullURL)
    }

    @Test("All candidates failing surfaces an error")
    func allCandidatesFailingSurfacesError() async {
        let resolver = makeResolver([:])

        await #expect(throws: (any Error).self) {
            try await resolver.resolve(candidates: serialShapedCandidates())
        }
    }

    @Test("No candidates surfaces an invalid feed error")
    func noCandidatesSurfacesInvalidFeedError() async {
        let resolver = makeResolver([:])

        await #expect(throws: OpenCastCoreError.invalidFeedURL) {
            try await resolver.resolve(candidates: [])
        }
    }

    @Test("Material difference thresholds")
    func materialDifferenceThresholds() {
        #expect(DirectoryFeedCandidateResolver.isMaterialDifference(33, 124))
        #expect(!DirectoryFeedCandidateResolver.isMaterialDifference(120, 124))
        // Ten-episode floor: 9 fails even at a high fraction.
        #expect(!DirectoryFeedCandidateResolver.isMaterialDifference(1, 10))
        #expect(DirectoryFeedCandidateResolver.isMaterialDifference(0, 10))
        // Twenty-percent floor: 10 of 1000 fails.
        #expect(!DirectoryFeedCandidateResolver.isMaterialDifference(990, 1000))
        #expect(DirectoryFeedCandidateResolver.isMaterialDifference(100, 125))
        #expect(!DirectoryFeedCandidateResolver.isMaterialDifference(0, 0))
    }

    private func serialShapedCandidates() -> [DirectoryFeedCandidate] {
        [
            DirectoryFeedCandidate(source: .apple, feedURL: windowedURL),
            DirectoryFeedCandidate(source: .podcastIndex, feedURL: fullURL, reportedEpisodeCount: 124),
        ]
    }

    private func makeResolver(
        _ snapshots: [URL: FeedSnapshot],
        finalURLs: [URL: URL] = [:]
    ) -> DirectoryFeedCandidateResolver {
        DirectoryFeedCandidateResolver(
            feedService: StubResolverFeedService(snapshots: snapshots, finalURLs: finalURLs)
        )
    }

    private func makeSnapshot(
        feedURL: URL,
        episodeCount: Int,
        newest: Date,
        isSalvaged: Bool = false,
        podcastGUID: String? = nil
    ) -> FeedSnapshot {
        let podcastID = URLCanonicalizer.podcastID(for: feedURL)
        let episodes = (0..<episodeCount).map { index in
            Episode(
                id: EpisodeID(rawValue: "\(podcastID.rawValue)#episode-\(index)"),
                podcastID: podcastID,
                podcastTitle: "Fixture Show",
                title: "Episode \(episodeCount - index)",
                publishedAt: newest.addingTimeInterval(TimeInterval(-index * 24 * 60 * 60)),
                audioURL: URL(string: "https://audio.example.com/\(index).mp3"),
                guid: "episode-\(index)"
            )
        }
        return FeedSnapshot(
            podcast: Podcast(
                id: podcastID,
                feedURL: feedURL,
                title: "Fixture Show",
                podcastGUID: podcastGUID
            ),
            episodes: episodes,
            isSalvaged: isSalvaged
        )
    }

    private func choiceCase(from resolution: DirectoryFeedResolution) -> DirectoryFeedChoice? {
        if case .choice(let choice) = resolution {
            return choice
        }
        return nil
    }

    private func subscribedCase(from resolution: DirectoryFeedResolution) -> ResolvedFeedCandidate? {
        if case .subscribe(let resolved) = resolution {
            return resolved
        }
        return nil
    }
}

private struct StubResolverFeedService: FeedService {
    let snapshots: [URL: FeedSnapshot]
    let finalURLs: [URL: URL]

    func fetchFeed(at url: URL) async throws -> FeedSnapshot {
        guard let snapshot = snapshots[url] else {
            throw OpenCastCoreError.unexpectedStatusCode(404)
        }
        return snapshot
    }

    func fetchFeedOutcome(at url: URL, validators: FeedValidators?) async throws -> FeedFetchOutcome {
        FeedFetchOutcome(snapshot: try await fetchFeed(at: url), finalURL: finalURLs[url] ?? url)
    }
}
