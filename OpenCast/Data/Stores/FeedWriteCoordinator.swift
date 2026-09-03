import Foundation
import Observation
import OpenCastCore
import SwiftData

/// The library's feed-write path: cache upserts with episode-identity
/// reconciliation, subscription migration onto a relocated feed, redirect
/// and https-upgrade advice, and the duplicate-episode merge sweep. Both the
/// core store's add flows and the refresh flow write through this type; it
/// never calls back into either, only into the injected publication
/// closures. Every synced save goes through the ledger, and every await
/// that precedes a write is fenced by the shared write generation.
@Observable
final class FeedWriteCoordinator {
    /// Feeds whose refreshes keep landing on a different host: the podcast
    /// page offers "Update Feed Address" instead of migrating automatically,
    /// because redirects are routinely CDN noise. Session-scoped state.
    private(set) var suggestedFeedMigrationURLsByFeedURL: [String: URL] = [:]

    /// Episode-keyed device-local stores (downloads, transcripts, ad
    /// analyses) that identity reconciliation carries across an ID change;
    /// wired by OpenCastAppModel at composition.
    @ObservationIgnored var sidecarMigrators: [any EpisodeIdentitySidecarMigrating] = []
    /// Republication after a migration or merge sweep, wired by LibraryStore:
    /// the full library reload and the progress-projection refetch.
    @ObservationIgnored var reloadLibrary: (ModelContext) async throws -> Void = { _ in }
    @ObservationIgnored var reloadProgress: (ModelContext) throws -> Void = { _ in }

    // Deliberately survives resetAfterDataNuke — observed session-scoped
    // behavior, decision deferred.
    @ObservationIgnored private var relocationAdvisor = FeedRelocationAdvisor()
    @ObservationIgnored private let feedService: any FeedService
    @ObservationIgnored private let localCache: any LocalLibraryCacheStore
    @ObservationIgnored private let ledger: SyncedStoreSelfSaveLedger
    @ObservationIgnored private let writeGeneration: LibraryWriteGeneration

    init(
        feedService: any FeedService,
        localCache: any LocalLibraryCacheStore,
        ledger: SyncedStoreSelfSaveLedger,
        writeGeneration: LibraryWriteGeneration
    ) {
        self.feedService = feedService
        self.localCache = localCache
        self.ledger = ledger
        self.writeGeneration = writeGeneration
    }

    func upsert(
        snapshot: FeedSnapshot,
        modelContext: ModelContext,
        subscribe: Bool,
        generation: Int
    ) async throws -> Bool {
        let canonicalFeedURL = snapshot.podcast.id.rawValue
        let now = Date.now

        var subscriptionDescriptor = FetchDescriptor<SubscriptionRecord>(
            predicate: #Predicate { record in
                record.feedURL == canonicalFeedURL
            }
        )
        subscriptionDescriptor.fetchLimit = 1
        let hasExistingSubscription = try modelContext.fetch(subscriptionDescriptor).first != nil
        guard hasExistingSubscription || subscribe else {
            // The feed was unsubscribed while its refresh was in flight;
            // writing the cache now would resurrect rows nothing deletes again.
            return false
        }

        let preexistingEpisodes = try await localCache.cachedEpisodes(forPodcastID: canonicalFeedURL)
        try writeGeneration.ensureCurrent(generation)
        try await localCache.upsertCache(from: snapshot, refreshedAt: now)
        do {
            try writeGeneration.ensureCurrent(generation)
        } catch {
            // The nuke ran while the cache write was in flight; the rows it
            // just wrote would outlive the wipe as orphans.
            try await localCache.deleteCache(forPodcastID: canonicalFeedURL)
            throw error
        }
        try await reconcileEpisodeIdentities(
            preexisting: preexistingEpisodes,
            snapshot: snapshot,
            includesEstablishedSuccessors: false,
            generation: generation,
            modelContext: modelContext
        )
        // Checked before the fetch-and-mutate below rather than at the save:
        // nothing suspends in between, and unwinding here leaves no dirty
        // subscription behind for an unrelated save to commit.
        try writeGeneration.ensureCurrent(generation)

        // Synced-record writes are held to actual changes: every dirtied
        // field exports a CKRecord and round-trips through every device, and
        // routine refreshes used to re-write identical metadata for the whole
        // library. Refresh recency itself is deliberately device-local (the
        // refresh logs) — syncing it starved other devices' own refreshes and
        // kept every subscription record permanently churning.
        var hasSyncedChanges = false
        if let existingSubscription = try modelContext.fetch(subscriptionDescriptor).first {
            hasSyncedChanges = update(existingSubscription, from: snapshot)
        } else if subscribe {
            modelContext.insert(
                SubscriptionRecord(
                    feedURL: canonicalFeedURL,
                    title: snapshot.podcast.title,
                    author: snapshot.podcast.author,
                    artworkURL: snapshot.podcast.artworkURL?.absoluteString,
                    lastRefreshAt: now
                )
            )
            hasSyncedChanges = true
        } else {
            // The feed was unsubscribed while its refresh was in flight;
            // remove the just-written local cache so the unsubscribe stays complete.
            try await localCache.deleteCache(forPodcastID: canonicalFeedURL)
            return false
        }

        if hasSyncedChanges {
            try ledger.save(modelContext)
        }
        return true
    }

    /// Re-keys departed episode IDs onto their re-identified successors after
    /// a cache write: publishers that add or change GUIDs (or a GUID-less
    /// feed that moves hosts) mint a whole new catalog, and without this the
    /// old rows linger as duplicates while progress, downloads, transcripts,
    /// and ad analyses stay orphaned on the dead IDs forever.
    ///
    /// Refresh passes only consider successors whose IDs are new to the cache
    /// (`includesEstablishedSuccessors: false`) so a merely-removed episode
    /// can never be folded into a long-stable one; the manual merge sweep
    /// passes `true` because its departed rows are historic duplicates whose
    /// successors are already cached. Unmatched departed rows are retained as
    /// off-feed back-catalog — deletion happens only for migrated rows.
    ///
    /// The old-ID progress rows re-key (merging when the successor already
    /// has progress) and an `episode-progress` tombstone for each old ID
    /// lands in the same save, so old-ID twins on other devices die instead
    /// of resurrecting. Tombstones index by episode ID alone, so they can
    /// never touch the migrated new-ID rows; recency is deliberately left
    /// untouched so a peer's genuinely newer progress still wins its merge.
    @discardableResult
    private func reconcileEpisodeIdentities(
        preexisting: [EpisodeListItemSnapshot],
        snapshot: FeedSnapshot,
        includesEstablishedSuccessors: Bool,
        generation: Int,
        modelContext: ModelContext
    ) async throws -> Int {
        guard !preexisting.isEmpty else {
            return 0
        }
        let canonicalFeedURL = snapshot.podcast.id.rawValue
        let snapshotIDs = Set(snapshot.episodes.map(\.id.rawValue))
        let preexistingIDs = Set(preexisting.map(\.episodeID))

        let departed = preexisting
            .filter { !snapshotIDs.contains($0.episodeID) }
            .map(EpisodeIdentityReconciler.Candidate.init(listItem:))
        guard !departed.isEmpty else {
            return 0
        }

        let successors = snapshot.episodes
            .filter { includesEstablishedSuccessors || !preexistingIDs.contains($0.id.rawValue) }
            .map(EpisodeIdentityReconciler.Candidate.init(episode:))
        guard !successors.isEmpty else {
            return 0
        }

        let matches = EpisodeIdentityReconciler.matches(departed: departed, successors: successors)
        guard !matches.isEmpty else {
            return 0
        }

        // The callers' awaits all precede this point; the apply-and-save
        // pair below is synchronous, so one check covers the save.
        try writeGeneration.ensureCurrent(generation)
        try EpisodeIdentityMigrationApplier.apply(
            matches,
            canonicalFeedURL: canonicalFeedURL,
            sidecarMigrators: sidecarMigrators,
            modelContext: modelContext
        )
        try ledger.save(modelContext)
        try await localCache.deleteEpisodes(episodeIDs: matches.map(\.departedEpisodeID))
        return matches.count
    }

    func handleFeedRelocation(
        _ outcome: FeedFetchOutcome,
        feedURLString: String,
        generation: Int,
        modelContext: ModelContext
    ) async throws {
        try writeGeneration.ensureCurrent(generation)
        let canonicalFeedURL = URLCanonicalizer.canonicalString(forRawString: feedURLString)

        if let newFeedURL = outcome.newFeedURL,
           URLCanonicalizer.canonicalString(for: newFeedURL) != canonicalFeedURL {
            // The tag is the publisher's explicit instruction; migration
            // performs its own fetch of the new URL and only commits when
            // that fetch succeeds.
            do {
                try await migrateSubscription(
                    from: feedURLString,
                    toFeedURL: newFeedURL,
                    generation: generation,
                    modelContext: modelContext
                )
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // The declared URL doesn't serve a usable feed yet; stay put.
            }
        }

        updateRedirectDivergence(feedURLString: feedURLString, finalURL: outcome.finalURL)
        try await probeHTTPSUpgradeIfNeeded(
            feedURLString: feedURLString,
            generation: generation,
            modelContext: modelContext
        )
    }

    private func updateRedirectDivergence(feedURLString: String, finalURL: URL?) {
        switch relocationAdvisor.recordRedirect(feedURLString: feedURLString, finalURL: finalURL) {
        case .clearSuggestion:
            if suggestedFeedMigrationURLsByFeedURL[feedURLString] != nil {
                suggestedFeedMigrationURLsByFeedURL[feedURLString] = nil
            }
        case .none:
            break
        case .suggest(let migrationURL):
            suggestedFeedMigrationURLsByFeedURL[feedURLString] = migrationURL
        }
    }

    /// `http://` feeds stay supported and are never rewritten blindly; when
    /// the https twin demonstrably serves the same show (identity overlap),
    /// the subscription upgrades onto it. One probe per feed per launch.
    private func probeHTTPSUpgradeIfNeeded(
        feedURLString: String,
        generation: Int,
        modelContext: ModelContext
    ) async throws {
        guard let feedURL = URL(string: feedURLString),
              feedURL.scheme?.lowercased() == "http",
              relocationAdvisor.shouldProbeHTTPSUpgrade(feedURLString)
        else {
            return
        }

        var components = URLComponents(url: feedURL, resolvingAgainstBaseURL: false)
        components?.scheme = "https"
        guard let httpsURL = components?.url else {
            return
        }

        do {
            try await migrateSubscription(
                from: feedURLString,
                toFeedURL: httpsURL,
                requiresIdentityOverlap: true,
                generation: generation,
                modelContext: modelContext
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // No https twin, or it serves something else — keep the http feed.
        }
    }

    /// Moves a subscription onto a new canonical feed URL: fetches the new
    /// URL (the migration only commits when that fetch succeeds), re-keys
    /// episode identities through the reconciliation machinery, writes the
    /// old URL's subscription tombstone and the fresh SubscriptionRecord in
    /// the same save, then drops the old URL's local cache.
    ///
    /// `generation` is the refresh flow's captured write generation; the
    /// public path captures its own at entry.
    func migrateSubscription(
        from oldFeedURLString: String,
        toFeedURL newFeedURL: URL,
        requiresIdentityOverlap: Bool = false,
        generation: Int? = nil,
        modelContext: ModelContext
    ) async throws {
        let generation = generation ?? writeGeneration.capture()
        let outcome = try await feedService.fetchFeedOutcome(at: newFeedURL)
        try writeGeneration.ensureCurrent(generation)
        guard let snapshot = outcome.snapshot else {
            throw OpenCastCoreError.invalidHTTPResponse
        }
        let newCanonicalFeedURL = snapshot.podcast.id.rawValue
        let oldCanonicalFeedURL = URLCanonicalizer.canonicalString(forRawString: oldFeedURLString)
        guard newCanonicalFeedURL != oldCanonicalFeedURL else {
            return
        }

        let allSubscriptions = try modelContext.fetch(FetchDescriptor<SubscriptionRecord>())
        let oldSubscriptionRecords = allSubscriptions.filter { record in
            URLCanonicalizer.canonicalString(forRawString: record.feedURL) == oldCanonicalFeedURL
        }
        guard let template = oldSubscriptionRecords.first else {
            return
        }

        let departed = try await localCache.cachedEpisodes(forPodcastID: oldCanonicalFeedURL)
            .map(EpisodeIdentityReconciler.Candidate.init(listItem:))
        let successors = snapshot.episodes.map(EpisodeIdentityReconciler.Candidate.init(episode:))
        let matches = EpisodeIdentityReconciler.matches(departed: departed, successors: successors)
        if requiresIdentityOverlap, !departed.isEmpty, matches.isEmpty {
            throw FeedMigrationError(message: "The feed at the new address does not match this show.")
        }

        try await localCache.upsertCache(from: snapshot, refreshedAt: .now)
        do {
            // Everything from here to the save is synchronous, so this one
            // check covers the save; on unwind the new URL's fresh cache
            // rows would otherwise outlive the wipe as orphans.
            try writeGeneration.ensureCurrent(generation)
        } catch {
            try await localCache.deleteCache(forPodcastID: newCanonicalFeedURL)
            throw error
        }
        try EpisodeIdentityMigrationApplier.apply(
            matches,
            canonicalFeedURL: newCanonicalFeedURL,
            sidecarMigrators: sidecarMigrators,
            modelContext: modelContext
        )

        let deletedAt = Date.now
        modelContext.insert(
            SyncTombstoneRecord(scope: .subscription, feedURL: oldCanonicalFeedURL, deletedAt: deletedAt)
        )
        let hasNewSubscription = allSubscriptions.contains { record in
            URLCanonicalizer.canonicalString(forRawString: record.feedURL) == newCanonicalFeedURL
        }
        let migrationSkipSettings = PodcastPlaybackSkipSettings.greatestValid(
            in: oldSubscriptionRecords.map {
                PodcastPlaybackSkipSettings(
                    skipIntroSeconds: $0.skipIntroSeconds,
                    skipOutroSeconds: $0.skipOutroSeconds
                )
            }
        )
        if !hasNewSubscription {
            // subscribedAt must postdate the old URL's tombstone only if the
            // keys collided — they don't — but a strictly newer stamp keeps
            // the record safe under any future canonicalization drift.
            modelContext.insert(
                SubscriptionRecord(
                    feedURL: newCanonicalFeedURL,
                    title: snapshot.podcast.title,
                    author: snapshot.podcast.author,
                    artworkURL: snapshot.podcast.artworkURL?.absoluteString,
                    subscribedAt: deletedAt.addingTimeInterval(1),
                    lastRefreshAt: .now,
                    isArchived: template.isArchived,
                    isVoiceBoostEnabled: template.isVoiceBoostEnabled,
                    isAdAutoDetectEnabled: template.isAdAutoDetectEnabled,
                    isTranscriptAnalysisEnabled: template.isTranscriptAnalysisEnabled,
                    skipIntroSeconds: migrationSkipSettings.skipIntroSeconds,
                    skipOutroSeconds: migrationSkipSettings.skipOutroSeconds
                )
            )
        } else {
            for record in allSubscriptions where
                URLCanonicalizer.canonicalString(forRawString: record.feedURL) == newCanonicalFeedURL
            {
                Self.mergePodcastPlaybackSkipSettings(
                    migrationSkipSettings,
                    into: record
                )
            }
        }
        for record in oldSubscriptionRecords {
            modelContext.delete(record)
        }
        try ledger.save(modelContext)

        try await localCache.deleteCache(forPodcastID: oldCanonicalFeedURL)
        relocationAdvisor.clearDivergence(oldFeedURLString)
        if suggestedFeedMigrationURLsByFeedURL[oldFeedURLString] != nil {
            suggestedFeedMigrationURLsByFeedURL[oldFeedURLString] = nil
        }
        // The migration is committed; only the republication is at stake. A
        // nuke that landed during the cache delete must not have its reset
        // store repopulated from a cache it is about to clear.
        try writeGeneration.ensureCurrent(generation)
        try await reloadLibrary(modelContext)
        try reloadProgress(modelContext)
    }

    @discardableResult
    static func mergePodcastPlaybackSkipSettings(
        _ incoming: PodcastPlaybackSkipSettings,
        into record: SubscriptionRecord
    ) -> Bool {
        let current = PodcastPlaybackSkipSettings(
            skipIntroSeconds: record.skipIntroSeconds,
            skipOutroSeconds: record.skipOutroSeconds
        )
        let merged = current.mergingGreatestValid(with: incoming)
        var changed = false
        if record.skipIntroSeconds != merged.skipIntroSeconds {
            record.skipIntroSeconds = merged.skipIntroSeconds
            changed = true
        }
        if record.skipOutroSeconds != merged.skipOutroSeconds {
            record.skipOutroSeconds = merged.skipOutroSeconds
            changed = true
        }
        return changed
    }

    /// Diagnostics sweep for libraries duplicated before reconciliation
    /// existed: refetches every subscribed feed and reconciles departed rows
    /// against the feed's full current catalog (successors may already be
    /// cached, which routine refreshes deliberately skip).
    func mergeDuplicateEpisodes(
        feedURLStrings: [String],
        modelContext: ModelContext
    ) async throws -> EpisodeMergeResult {
        let generation = writeGeneration.capture()
        var result = EpisodeMergeResult()
        for feedURLString in feedURLStrings {
            guard let feedURL = URL(string: feedURLString),
                  feedURL.scheme != nil,
                  feedURL.host != nil
            else {
                result.failedFeedURLs.append(feedURLString)
                continue
            }
            do {
                let snapshot = try await feedService.fetchFeed(at: feedURL)
                try Task.checkCancellation()
                let canonicalFeedURL = snapshot.podcast.id.rawValue
                let preexisting = try await localCache.cachedEpisodes(forPodcastID: canonicalFeedURL)
                result.episodesMigrated += try await reconcileEpisodeIdentities(
                    preexisting: preexisting,
                    snapshot: snapshot,
                    includesEstablishedSuccessors: true,
                    generation: generation,
                    modelContext: modelContext
                )
                _ = try await upsert(
                    snapshot: snapshot,
                    modelContext: modelContext,
                    subscribe: false,
                    generation: generation
                )
                result.feedsProcessed += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                result.failedFeedURLs.append(feedURLString)
            }
        }
        try await reloadLibrary(modelContext)
        try reloadProgress(modelContext)
        return result
    }

    private func update(_ subscription: SubscriptionRecord, from snapshot: FeedSnapshot) -> Bool {
        var hasChanges = false
        if subscription.title != snapshot.podcast.title {
            subscription.title = snapshot.podcast.title
            hasChanges = true
        }
        if subscription.author != snapshot.podcast.author {
            subscription.author = snapshot.podcast.author
            hasChanges = true
        }
        let artworkURL = snapshot.podcast.artworkURL?.absoluteString
        if subscription.artworkURL != artworkURL {
            subscription.artworkURL = artworkURL
            hasChanges = true
        }
        if subscription.isArchived {
            subscription.isArchived = false
            hasChanges = true
        }
        return hasChanges
    }
}
