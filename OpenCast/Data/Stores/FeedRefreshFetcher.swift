import Foundation
import OpenCastCore

enum FeedRefreshFetcher {
    /// Wide enough to hide network latency, narrow enough not to flood feed hosts or starve the main
    /// actor applying results.
    static let maxConcurrentFeedRefreshes = 4

    struct Result: Sendable {
        var feedURLString: String
        var outcome: Outcome
    }

    enum Outcome: Sendable {
        case success(PreparedFeedOutcome)
        case failure(String)
        /// The device could not put the request on the network.
        case unreachable(String)
        case cancelled
    }

    nonisolated static func fetchResult(
        feedURLString: String,
        feedService: any FeedService,
        localCache: any LocalLibraryCacheStore,
        intent: FeedPreparationIntent = .interactive
    ) async -> Result {
        guard let feedURL = URL(string: feedURLString),
              feedURL.scheme != nil,
              feedURL.host != nil
        else {
            return Result(
                feedURLString: feedURLString,
                outcome: .failure(OpenCastCoreError.invalidFeedURL.localizedDescription)
            )
        }

        do {
            let canonicalFeedURL = URLCanonicalizer.canonicalString(forRawString: feedURLString)
            let storedValidators = (try? await localCache.feedValidators(forPodcastID: canonicalFeedURL)) ?? nil
            let outcome = try await feedService.prepareFeed(
                at: feedURL,
                validators: storedValidators,
                intent: intent
            )
            try Task.checkCancellation()
            return Result(feedURLString: feedURLString, outcome: .success(outcome))
        } catch is CancellationError {
            return Result(feedURLString: feedURLString, outcome: .cancelled)
        } catch {
            if Task.isCancelled {
                return Result(feedURLString: feedURLString, outcome: .cancelled)
            }
            if FeedTransportErrorClassifier.isUnreachable(error) {
                return Result(feedURLString: feedURLString, outcome: .unreachable(error.localizedDescription))
            }
            return Result(feedURLString: feedURLString, outcome: .failure(error.localizedDescription))
        }
    }

    /// Seeds the next fetch before applying a result, so the window stays full while `apply` runs.
    /// An error thrown by `apply` cancels the remaining fetches.
    static func forEachResult(
        feedURLStrings: [String],
        feedService: any FeedService,
        localCache: any LocalLibraryCacheStore,
        intent: FeedPreparationIntent = .interactive,
        apply: (Result) async throws -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: Result.self) { group in
            var unseededFeedURLStrings = feedURLStrings[...]
            func seedNextFetch() {
                guard let feedURLString = unseededFeedURLStrings.popFirst() else {
                    return
                }
                group.addTask {
                    await fetchResult(
                        feedURLString: feedURLString,
                        feedService: feedService,
                        localCache: localCache,
                        intent: intent
                    )
                }
            }

            for _ in 0..<maxConcurrentFeedRefreshes {
                seedNextFetch()
            }

            for try await result in group {
                seedNextFetch()
                try await apply(result)
            }
        }
    }
}
