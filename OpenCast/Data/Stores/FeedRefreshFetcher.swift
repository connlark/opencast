import Foundation
import OpenCastCore

/// Bounded-concurrency feed fetching shared by the bulk refresh and batch
/// subscribe flows: fetches run off the main actor at the shared width while
/// each result applies serially through the caller's closure. Cancellation
/// fencing, generation checks, and busy-marker bookkeeping deliberately stay
/// with the caller — this type only fetches and hands results back.
enum FeedRefreshFetcher {
    /// Bounded fetch fan-out shared by refreshAll and subscribeBatch: wide
    /// enough to hide network latency, narrow enough not to flood the feed
    /// hosts or starve the main actor with result application.
    static let maxConcurrentFeedRefreshes = 4

    struct Result: Sendable {
        var feedURLString: String
        var outcome: Outcome
    }

    enum Outcome: Sendable {
        case success(FeedFetchOutcome)
        case failure(String)
        case cancelled
    }

    nonisolated static func fetchResult(
        feedURLString: String,
        feedService: any FeedService,
        localCache: any LocalLibraryCacheStore
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
            let outcome = try await feedService.fetchFeedOutcome(at: feedURL, validators: storedValidators)
            try Task.checkCancellation()
            return Result(feedURLString: feedURLString, outcome: .success(outcome))
        } catch is CancellationError {
            return Result(feedURLString: feedURLString, outcome: .cancelled)
        } catch {
            if Task.isCancelled {
                return Result(feedURLString: feedURLString, outcome: .cancelled)
            }
            return Result(feedURLString: feedURLString, outcome: .failure(error.localizedDescription))
        }
    }

    /// The sliding-window driver: seeds up to the shared width, then applies
    /// each result as it lands, seeding the next fetch first so the window
    /// stays full. An error thrown by `apply` cancels the remaining fetches.
    static func forEachResult(
        feedURLStrings: [String],
        feedService: any FeedService,
        localCache: any LocalLibraryCacheStore,
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
                        localCache: localCache
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
