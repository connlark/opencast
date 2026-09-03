import Foundation
import Observation
import OpenCastCore
import SwiftData

/// The library's refresh flows: the single-feed, bulk, stale and
/// missing-cache entry points, the shared flow shell (generation capture,
/// refreshing/idle transitions, trailing publication, cancellation is not an
/// error), fetch-result application, validator persistence, refresh-log
/// writes, and the per-feed busy markers. Its own writes go to SQLite
/// through the local cache, never through a ModelContext, so it holds no
/// self-save ledger; every await that precedes a write is fenced by the
/// shared write generation. Feed content lands through
/// `FeedWriteCoordinator`; the observable state machine and publication
/// stay with the host store.
@Observable
final class FeedRefreshCoordinator {
    private(set) var refreshCompletedToken = 0

    var refreshingFeedURLs: Set<String> {
        Set(refreshingFeedURLCounts.keys)
    }

    // Busy-marker bookkeeping is reference-counted through the begin/end
    // helpers so overlapping flows (a single-feed refresh during a bulk
    // refresh) provably balance on success, error, and cancellation. Rows
    // observe their feed's activity object, so per-feed marker changes never
    // invalidate every subscription row.
    @ObservationIgnored private var refreshingFeedURLCounts: [String: Int] = [:]
    @ObservationIgnored private var refreshActivityByFeedURL: [String: FeedRefreshActivity] = [:]
    @ObservationIgnored private unowned let host: any FeedRefreshHost
    @ObservationIgnored private let feedService: any FeedService
    @ObservationIgnored private let localCache: any LocalLibraryCacheStore
    @ObservationIgnored private let feedWrites: FeedWriteCoordinator
    @ObservationIgnored private let writeGeneration: LibraryWriteGeneration

    init(
        host: any FeedRefreshHost,
        feedService: any FeedService,
        localCache: any LocalLibraryCacheStore,
        feedWrites: FeedWriteCoordinator,
        writeGeneration: LibraryWriteGeneration
    ) {
        self.host = host
        self.feedService = feedService
        self.localCache = localCache
        self.feedWrites = feedWrites
        self.writeGeneration = writeGeneration
    }

    func refresh(feedURL: String, modelContext: ModelContext) async {
        // Mark the feed busy before the first suspension so refreshAllIfStale
        // cannot start a duplicate refresh while this one is in flight.
        beginRefreshing([feedURL])
        defer {
            endRefreshing([feedURL])
        }
        await performRefreshFlow(setsRefreshingState: false, modelContext: modelContext) { generation in
            guard let subscription = try host.activeSubscription(feedURL: feedURL, modelContext: modelContext) else {
                return .skip
            }

            let didChangeContent = try await refresh(
                subscription: subscription,
                generation: generation,
                modelContext: modelContext
            )
            return didChangeContent ? .full : .logsOnly
        }
    }

    func refreshAll(modelContext: ModelContext) async {
        let didComplete = await performRefreshFlow(setsRefreshingState: true, modelContext: modelContext) { generation in
            // The refresh set only needs the active feed URLs; the trailing
            // reload applies results, so a leading full-library reload would
            // pay the whole SQLite materialization for a subscription fetch.
            let feedURLStrings = try host.activeSubscriptionFeedURLStrings(modelContext: modelContext)
            try await refreshAll(
                feedURLStrings: feedURLStrings,
                generation: generation,
                modelContext: modelContext
            )
            return .full
        }
        if didComplete {
            refreshCompletedToken += 1
        }
    }

    func refreshAllIfStale(modelContext: ModelContext, now: Date = .now) async {
        guard host.state != .refreshing, refreshingFeedURLCounts.isEmpty else {
            return
        }

        let staleFeedURLStrings = staleFeedURLStrings(now: now)
        guard !staleFeedURLStrings.isEmpty else {
            return
        }

        await performRefreshFlow(setsRefreshingState: true, modelContext: modelContext) { generation in
            try await refreshAll(
                feedURLStrings: staleFeedURLStrings,
                generation: generation,
                modelContext: modelContext
            )
            return .full
        }
    }

    @discardableResult
    func refreshFeedsNeedingLocalCache(modelContext: ModelContext) async -> Bool {
        guard host.state != .refreshing, refreshingFeedURLCounts.isEmpty else {
            return false
        }

        let feedURLStrings = host.feedURLStringsNeedingLocalCache
        guard !feedURLStrings.isEmpty else {
            return false
        }

        return await performRefreshFlow(setsRefreshingState: true, modelContext: modelContext) { generation in
            try await refreshAll(
                feedURLStrings: feedURLStrings,
                generation: generation,
                modelContext: modelContext
            )
            return .full
        }
    }

    /// What a refresh flow's `work` closure asks the trailing publication to
    /// do. A single-feed refresh that fetched no new content (not-modified,
    /// or a failure that only wrote a log) republishes just the refresh-log
    /// projection instead of rematerializing the whole library.
    private enum RefreshFlowReload {
        case skip
        case full
        case logsOnly
    }

    /// The shared refresh-flow shell: generation capture, refreshing/idle
    /// state transitions, the trailing store reload, and the
    /// cancellation-is-not-an-error contract. Bulk flows set the observable
    /// refreshing state; the single-feed flow relies on per-feed markers and
    /// leaves a concurrently running bulk flow's state untouched. `.skip`
    /// from `work` skips the trailing reload (nothing was fetched). Returns
    /// true only when the flow ran to full success.
    @discardableResult
    private func performRefreshFlow(
        setsRefreshingState: Bool,
        modelContext: ModelContext,
        _ work: (_ generation: Int) async throws -> RefreshFlowReload
    ) async -> Bool {
        let generation = writeGeneration.capture()
        if setsRefreshingState {
            host.state = .refreshing
        }
        host.lastErrorMessage = nil
        do {
            switch try await work(generation) {
            case .skip:
                if host.state != .refreshing {
                    host.state = .idle
                }
                return false
            case .full:
                try await host.reloadFromStore(modelContext: modelContext)
            case .logsOnly:
                try await host.reloadRefreshLogsFromStore()
            }
            if setsRefreshingState || host.state != .refreshing {
                host.state = .idle
            }
            return true
        } catch is CancellationError {
            // Real task cancellation still publishes whatever partial results
            // landed. A flow the data nuke unwound must not: its reload would
            // take a fresh reload generation and republish the cache the
            // nuke is clearing into the reset store.
            if writeGeneration.isCurrent(generation) {
                try? await host.reloadFromStore(modelContext: modelContext)
            }
            if setsRefreshingState || host.state != .refreshing {
                host.state = .idle
            }
            return false
        } catch {
            host.recordFailure(error)
            return false
        }
    }

    /// Returns true when new feed content was upserted; log-only outcomes
    /// (not-modified, recorded failures) return false.
    private func refresh(
        subscription: SubscriptionRecord,
        generation: Int,
        modelContext: ModelContext
    ) async throws -> Bool {
        let startedAt = Date.now
        let result = await FeedRefreshFetcher.fetchResult(
            feedURLString: subscription.feedURL,
            feedService: feedService,
            localCache: localCache
        )
        try Task.checkCancellation()
        try writeGeneration.ensureCurrent(generation)
        return try await applyRefreshResult(
            result,
            startedAt: startedAt,
            generation: generation,
            modelContext: modelContext
        )
    }

    private func refreshAll(
        feedURLStrings: [String],
        generation: Int,
        modelContext: ModelContext
    ) async throws {
        let feedURLStrings = uniqueFeedURLStrings(from: feedURLStrings)
        guard !feedURLStrings.isEmpty else {
            return
        }

        let startedAt = Date.now
        var pendingFeedURLStrings = Set(feedURLStrings)
        beginRefreshing(feedURLStrings)
        defer {
            endRefreshing(pendingFeedURLStrings)
        }

        try await FeedRefreshFetcher.forEachResult(
            feedURLStrings: feedURLStrings,
            feedService: feedService,
            localCache: localCache
        ) { result in
            try Task.checkCancellation()
            try self.writeGeneration.ensureCurrent(generation)
            pendingFeedURLStrings.remove(result.feedURLString)
            defer {
                self.endRefreshing([result.feedURLString])
            }
            _ = try await self.applyRefreshResult(
                result,
                startedAt: startedAt,
                generation: generation,
                modelContext: modelContext
            )
        }
    }

    /// Returns true when the feed's snapshot was upserted (content changed).
    private func applyRefreshResult(
        _ result: FeedRefreshFetcher.Result,
        startedAt: Date,
        generation: Int,
        modelContext: ModelContext
    ) async throws -> Bool {
        switch result.outcome {
        case .success(let outcome):
            do {
                guard let snapshot = outcome.snapshot else {
                    // Not-modified short-circuit: still a successful refresh.
                    await persistValidators(
                        outcome.validators,
                        forPodcastID: URLCanonicalizer.canonicalString(forRawString: result.feedURLString)
                    )
                    try await recordRefreshLog(
                        feedURL: result.feedURLString,
                        startedAt: startedAt,
                        errorMessage: nil,
                        generation: generation
                    )
                    return false
                }
                guard try await feedWrites.upsert(
                    snapshot: snapshot,
                    modelContext: modelContext,
                    subscribe: false,
                    generation: generation
                ) else {
                    return false
                }
                await persistValidators(outcome.validators, forPodcastID: snapshot.podcast.id.rawValue)
                try await recordRefreshLog(
                    feedURL: result.feedURLString,
                    startedAt: startedAt,
                    errorMessage: snapshot.isSalvaged ? RefreshLogSnapshot.partialFeedSalvageMessage : nil,
                    generation: generation
                )
                try await feedWrites.handleFeedRelocation(
                    outcome,
                    feedURLString: result.feedURLString,
                    generation: generation,
                    modelContext: modelContext
                )
                return true
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try await recordRefreshLog(
                    feedURL: result.feedURLString,
                    startedAt: startedAt,
                    errorMessage: error.localizedDescription,
                    generation: generation
                )
                return false
            }
        case .failure(let message):
            try await recordRefreshLog(
                feedURL: result.feedURLString,
                startedAt: startedAt,
                errorMessage: message,
                generation: generation
            )
            return false
        case .cancelled:
            throw CancellationError()
        }
    }

    /// Validator persistence is a refresh optimization: a failed write only
    /// costs the next fetch a full download, so it never fails the refresh.
    func persistValidators(_ validators: FeedValidators?, forPodcastID podcastID: String) async {
        guard let validators, !validators.isEmpty else {
            return
        }
        try? await localCache.updateFeedValidators(validators, forPodcastID: podcastID)
    }

    /// Refresh logs are written once, on completion. Cancelled refreshes write
    /// nothing, matching the previous insert-then-delete-on-cancel behavior.
    private func recordRefreshLog(
        feedURL: String,
        startedAt: Date,
        errorMessage: String?,
        generation: Int
    ) async throws {
        try writeGeneration.ensureCurrent(generation)
        try await localCache.insertRefreshLog(
            RefreshLogSnapshot(
                feedURL: feedURL,
                startedAt: startedAt,
                finishedAt: .now,
                errorMessage: errorMessage
            ),
            prunedTo: LibraryStore.refreshLogRetentionLimit
        )
    }

    func isRefreshing(feedURL: String) -> Bool {
        refreshActivity(for: feedURL).isRefreshing
    }

    private func refreshActivity(for feedURL: String) -> FeedRefreshActivity {
        if let activity = refreshActivityByFeedURL[feedURL] {
            return activity
        }

        let activity = FeedRefreshActivity()
        refreshActivityByFeedURL[feedURL] = activity
        return activity
    }

    private func beginRefreshing(_ feedURLStrings: some Sequence<String>) {
        for feedURLString in feedURLStrings {
            let count = refreshingFeedURLCounts[feedURLString, default: 0]
            refreshingFeedURLCounts[feedURLString] = count + 1
            if count == 0 {
                refreshActivity(for: feedURLString).isRefreshing = true
            }
        }
    }

    private func endRefreshing(_ feedURLStrings: some Sequence<String>) {
        for feedURLString in feedURLStrings {
            guard let count = refreshingFeedURLCounts[feedURLString] else {
                continue
            }
            if count <= 1 {
                refreshingFeedURLCounts.removeValue(forKey: feedURLString)
                refreshActivity(for: feedURLString).isRefreshing = false
            } else {
                refreshingFeedURLCounts[feedURLString] = count - 1
            }
        }
    }

    func clearAllRefreshMarkers() {
        refreshingFeedURLCounts.removeAll()
        for activity in refreshActivityByFeedURL.values {
            activity.isRefreshing = false
        }
    }

    private func staleFeedURLStrings(now: Date) -> [String] {
        host.subscriptions.compactMap { subscription in
            guard let lastRefreshActivity = lastRefreshActivity(for: subscription) else {
                return subscription.feedURL
            }

            return now.timeIntervalSince(lastRefreshActivity) >= LibraryStore.foregroundRefreshInterval
                ? subscription.feedURL
                : nil
        }
    }

    private func lastRefreshActivity(for subscription: SubscriptionRecord) -> Date? {
        [
            subscription.lastRefreshAt,
            host.latestRefreshLogByFeedURL[subscription.feedURL]?.startedAt
        ]
        .compactMap(\.self)
        .max()
    }

    private func uniqueFeedURLStrings(from feedURLStrings: [String]) -> [String] {
        var seenFeedURLStrings: Set<String> = []
        return feedURLStrings.filter { seenFeedURLStrings.insert($0).inserted }
    }
}
