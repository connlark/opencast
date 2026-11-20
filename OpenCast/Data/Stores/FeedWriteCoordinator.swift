import Foundation
import Observation
import OpenCastCore
import SwiftData

/// Every synced save goes through the ledger, and every await that precedes a write is fenced by
/// the shared write generation.
@Observable
final class FeedWriteCoordinator {
    /// Suggested rather than migrated, because redirects are routinely CDN noise. Session-scoped.
    private(set) var suggestedFeedMigrationURLsByFeedURL: [String: URL] = [:]

    @ObservationIgnored var sidecarMigrators: [any EpisodeIdentitySidecarMigrating] = []
    @ObservationIgnored var reloadLibrary: (ModelContext) async throws -> Void = { _ in }
    @ObservationIgnored var reloadProgress: (ModelContext) throws -> Void = { _ in }

    // Deliberately survives `resetAfterDataNuke`.
    @ObservationIgnored private var relocationAdvisor = FeedRelocationAdvisor()
    @ObservationIgnored private let feedService: any FeedService
    @ObservationIgnored private let localCache: any LocalLibraryCacheStore
    @ObservationIgnored private let ledger: SyncedStoreSelfSaveLedger
    @ObservationIgnored private let writeGeneration: LibraryWriteGeneration
    @ObservationIgnored private let now: () -> Date

    init(
        feedService: any FeedService,
        localCache: any LocalLibraryCacheStore,
        ledger: SyncedStoreSelfSaveLedger,
        writeGeneration: LibraryWriteGeneration,
        now: @escaping () -> Date
    ) {
        self.feedService = feedService
        self.localCache = localCache
        self.ledger = ledger
        self.writeGeneration = writeGeneration
        self.now = now
    }

    func upsert(
        prepared: PreparedFeed,
        modelContext: ModelContext,
        subscribe: Bool,
        generation: Int
    ) async throws -> Bool {
        let snapshot = prepared.isSalvaged
            ? FeedSnapshot(podcast: prepared.podcast, episodes: [], fetchedAt: prepared.fetchedAt,
                           isSalvaged: true, newFeedURL: prepared.newFeedURL)
            : try await prepared.identitySnapshot()
        try Task.checkCancellation()
        try writeGeneration.ensureCurrent(generation)
        return try await upsert(snapshot: snapshot, modelContext: modelContext, subscribe: subscribe,
                                generation: generation, prepared: prepared)
    }

    func upsert(
        snapshot: FeedSnapshot,
        modelContext: ModelContext,
        subscribe: Bool,
        generation: Int,
        prepared: PreparedFeed? = nil
    ) async throws -> Bool {
        try Task.checkCancellation()
        let canonicalFeedURL = snapshot.podcast.id.rawValue
        let now = now()

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

        let preexistingEpisodes = snapshot.isSalvaged ? [] : try await localCache.cachedEpisodes(forPodcastID: canonicalFeedURL)
        try writeGeneration.ensureCurrent(generation)
        if let prepared { try await localCache.upsertCache(from: prepared, refreshedAt: now) }
        else { try await localCache.upsertCache(from: snapshot, refreshedAt: now) }
        do {
            try writeGeneration.ensureCurrent(generation)
        } catch {
            // The nuke ran during the cache write, so the rows just written would outlive it as orphans.
            // A subscription that exists now was added after the reset and owns this cache; sweeping
            // would empty it until its next refresh. A failed fetch keeps the conservative sweep.
            let ownedByNewSubscription =
                (try? modelContext.fetch(subscriptionDescriptor))?.isEmpty == false
            if !ownedByNewSubscription {
                try await localCache.deleteCache(forPodcastID: canonicalFeedURL)
            }
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

        // Synced writes are held to actual changes: every dirtied field exports a CKRecord to every
        // device. Refresh recency stays device-local in the refresh logs; syncing it starved other
        // devices' refreshes and kept every subscription record churning.
        var hasSyncedChanges = false
        if let existingSubscription = try modelContext.fetch(subscriptionDescriptor).first {
            if !snapshot.isSalvaged { hasSyncedChanges = update(existingSubscription, from: snapshot) }
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

    /// With `includesEstablishedSuccessors` false only successors new to the cache match, so a merely
    /// removed episode is never folded into a long-stable one.
    @discardableResult
    private func reconcileEpisodeIdentities(
        preexisting: [EpisodeListItemSnapshot],
        snapshot: FeedSnapshot,
        includesEstablishedSuccessors: Bool,
        generation: Int,
        modelContext: ModelContext
    ) async throws -> Int {
        guard !snapshot.isSalvaged, !preexisting.isEmpty else {
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

        let matches = await EpisodeIdentityReconciler.matchesConcurrently(departed: departed, successors: successors)
        try Task.checkCancellation()
        guard !matches.isEmpty else {
            return 0
        }

        // The callers' awaits all precede this point; the apply-and-save
        // pair below is synchronous, so one check covers the save.
        try writeGeneration.ensureCurrent(generation)
        try commitIdentityMigration {
            try EpisodeIdentityMigrationApplier.apply(
                matches,
                canonicalFeedURL: canonicalFeedURL,
                sidecarMigrators: sidecarMigrators,
                modelContext: modelContext
            )
            try ledger.save(modelContext)
        }
        try await localCache.deleteEpisodes(episodeIDs: matches.map(\.departedEpisodeID))
        return matches.count
    }

    private func commitIdentityMigration(_ migrate: () throws -> Void) throws {
        do {
            try migrate()
        } catch {
            for migrator in sidecarMigrators {
                migrator.finishEpisodeSidecarMigration(committed: false)
            }
            throw error
        }
        for migrator in sidecarMigrators {
            migrator.finishEpisodeSidecarMigration(committed: true)
        }
    }

    func handleFeedRelocation(
        _ outcome: PreparedFeedOutcome,
        feedURLString: String,
        generation: Int,
        modelContext: ModelContext
    ) async throws {
        try writeGeneration.ensureCurrent(generation)
        guard outcome.feed?.isSalvaged != true else { return }
        let canonicalFeedURL = URLCanonicalizer.canonicalString(forRawString: feedURLString)

        if let newFeedURL = outcome.newFeedURL,
           URLCanonicalizer.canonicalString(for: newFeedURL) != canonicalFeedURL {
            // The tag is the publisher's explicit instruction, so it migrates; the migration commits only
            // if its own fetch of the new URL succeeds.
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

    /// Upgrades only when the https twin demonstrably serves the same show; an `http://` feed is never
    /// rewritten blindly.
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

    /// Commits only when its fetch of the new URL succeeds. A refresh flow passes its captured
    /// `generation`.
    func migrateSubscription(
        from oldFeedURLString: String,
        toFeedURL newFeedURL: URL,
        requiresIdentityOverlap: Bool = false,
        generation: Int? = nil,
        modelContext: ModelContext
    ) async throws {
        let generation = generation ?? writeGeneration.capture()
        let outcome = try await feedService.prepareFeed(
            at: newFeedURL,
            validators: nil,
            intent: .interactive
        )
        try writeGeneration.ensureCurrent(generation)
        guard let prepared = outcome.feed, prepared.completeness.isComplete else {
            throw OpenCastCoreError.malformedFeed(reason: "A complete feed is required to update its address.")
        }
        let snapshot = try await prepared.identitySnapshot()
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
        let matches = await EpisodeIdentityReconciler.matchesConcurrently(departed: departed, successors: successors)
        try Task.checkCancellation()
        if requiresIdentityOverlap, !departed.isEmpty, matches.isEmpty {
            throw FeedMigrationError(message: "The feed at the new address does not match this show.")
        }

        try await localCache.upsertCache(from: prepared, refreshedAt: now())
        do {
            // Everything from here to the save is synchronous, so this one
            // check covers the save; on unwind the new URL's fresh cache
            // rows would otherwise outlive the wipe as orphans.
            try writeGeneration.ensureCurrent(generation)
        } catch {
            try await localCache.deleteCache(forPodcastID: newCanonicalFeedURL)
            throw error
        }
        try commitIdentityMigration {
            try EpisodeIdentityMigrationApplier.apply(
                matches,
                canonicalFeedURL: newCanonicalFeedURL,
                sidecarMigrators: sidecarMigrators,
                modelContext: modelContext
            )
            for migrator in sidecarMigrators {
                try migrator.migrateFeedSidecars(
                    from: oldCanonicalFeedURL,
                    to: newCanonicalFeedURL,
                    modelContext: modelContext
                )
            }

            let deletedAt = now()
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
            let migrationPlaybackRate = PodcastPlaybackRateOverride.merged(
                oldSubscriptionRecords.map(\.playbackRate)
            )
            let migrationUpNextAutoAdd = UpNextAutoAddPosition.merged(
                oldSubscriptionRecords.map(\.autoAddToUpNext)
            )
            if !hasNewSubscription {
                // A stamp strictly newer than the old URL's tombstone keeps the record safe if
                // canonicalization ever maps both URLs to one key.
                modelContext.insert(
                    SubscriptionRecord(
                        feedURL: newCanonicalFeedURL,
                        title: snapshot.podcast.title,
                        author: snapshot.podcast.author,
                        artworkURL: snapshot.podcast.artworkURL?.absoluteString,
                        subscribedAt: deletedAt.addingTimeInterval(1),
                        lastRefreshAt: now(),
                        isArchived: template.isArchived,
                        isVoiceBoostEnabled: template.isVoiceBoostEnabled,
                        isAdAutoDetectEnabled: template.isAdAutoDetectEnabled,
                        isTranscriptAnalysisEnabled: template.isTranscriptAnalysisEnabled,
                        skipIntroSeconds: migrationSkipSettings.skipIntroSeconds,
                        skipOutroSeconds: migrationSkipSettings.skipOutroSeconds,
                        playbackRate: migrationPlaybackRate,
                        autoAddToUpNext: migrationUpNextAutoAdd
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
                    Self.mergePodcastPlaybackRate(migrationPlaybackRate, into: record)
                    Self.mergeUpNextAutoAdd(migrationUpNextAutoAdd, into: record)
                }
            }
            for record in oldSubscriptionRecords {
                modelContext.delete(record)
            }
            try ledger.save(modelContext)
        }

        try await localCache.deleteCache(forPodcastID: oldCanonicalFeedURL)
        relocationAdvisor.clearDivergence(oldFeedURLString)
        if suggestedFeedMigrationURLsByFeedURL[oldFeedURLString] != nil {
            suggestedFeedMigrationURLsByFeedURL[oldFeedURLString] = nil
        }
        // The migration is committed; a nuke that landed during the cache delete must not have its
        // reset store repopulated from a cache it is about to clear.
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

    @discardableResult
    static func mergePodcastPlaybackRate(
        _ incoming: Double,
        into record: SubscriptionRecord
    ) -> Bool {
        guard PodcastPlaybackRateOverride.resolved(record.playbackRate) == nil,
              PodcastPlaybackRateOverride.resolved(incoming) != nil
        else {
            return false
        }

        record.playbackRate = incoming
        return true
    }

    private static func mergeUpNextAutoAdd(_ incoming: Int, into record: SubscriptionRecord) {
        guard UpNextAutoAddPosition(stored: record.autoAddToUpNext) == nil,
              UpNextAutoAddPosition(stored: incoming) != nil
        else {
            return
        }

        record.autoAddToUpNext = incoming
    }

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
                guard let prepared = try await feedService.prepareFeed(
                    at: feedURL,
                    validators: nil,
                    intent: .interactive
                ).feed,
                      prepared.completeness.isComplete else {
                    throw OpenCastCoreError.malformedFeed(reason: "A complete feed is required to repair episode identities.")
                }
                let snapshot = try await prepared.identitySnapshot()
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
                    prepared: prepared,
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
