import Foundation
import Observation
import OpenCastCore
import SwiftData

/// Shared subscribe flow for directory results, used by Add Podcast,
/// onboarding, and Discover: enrich Apple-only results through the
/// Worker's Apple-ID lookup, resolve candidate feeds against their live
/// RSS, then subscribe directly or surface a feed choice.
@Observable
final class DirectorySubscriptionFlowStore {
    struct PendingChoice: Identifiable {
        let id = UUID()
        let result: DirectoryPodcastResult
        let choice: DirectoryFeedChoice
    }

    private(set) var subscribingResultID: String?
    var pendingChoice: PendingChoice?
    private(set) var errorMessage: String?

    @ObservationIgnored private let directoryService: any PodcastDirectoryService
    @ObservationIgnored private let resolver: DirectoryFeedCandidateResolver
    @ObservationIgnored private var subscriptionTask: Task<Void, Never>?
    @ObservationIgnored private var isPresenterDetached = false

    init(
        directoryService: any PodcastDirectoryService,
        resolver: DirectoryFeedCandidateResolver
    ) {
        self.directoryService = directoryService
        self.resolver = resolver
    }

    var isSubscribing: Bool {
        subscribingResultID != nil
    }

    func clearError() {
        errorMessage = nil
    }

    func waitForCurrentSubscription() async {
        await subscriptionTask?.value
    }

    func subscribe(
        to result: DirectoryPodcastResult,
        library: LibraryStore,
        modelContext: ModelContext,
        onSubscribed: @escaping () -> Void = {}
    ) {
        guard subscribingResultID == nil else {
            return
        }
        guard result.canResolveFeed else {
            return
        }

        errorMessage = nil
        subscribingResultID = result.id
        // Deliberately unscoped: the subscription finishes even if the
        // presenting sheet disappears, matching the raw-RSS path.
        subscriptionTask = Task {
            await resolveAndSubscribe(
                result: result,
                library: library,
                modelContext: modelContext,
                onSubscribed: onSubscribed
            )
        }
    }

    /// The user picked a candidate from the feed-choice presentation.
    func subscribe(
        candidate: ResolvedFeedCandidate,
        for pending: PendingChoice,
        library: LibraryStore,
        modelContext: ModelContext,
        onSubscribed: @escaping () -> Void = {}
    ) {
        pendingChoice = nil
        guard subscribingResultID == nil else {
            return
        }

        errorMessage = nil
        subscribingResultID = pending.result.id
        subscriptionTask = Task {
            await subscribeDirectly(
                feedURLString: candidate.candidate.feedURL.absoluteString,
                library: library,
                modelContext: modelContext,
                onSubscribed: onSubscribed
            )
        }
    }

    func dismissChoice() {
        pendingChoice = nil
    }

    /// The presenting view is gone for good (dismissed Add sheet,
    /// completed onboarding), so a feed choice can no longer be shown.
    /// The subscription the user started still finishes: an unanswered
    /// or later-resolved choice subscribes to its recommended primary
    /// candidate instead of being silently dropped. Long-lived
    /// presenters (Search) never detach — their choice sheet can still
    /// present late.
    func presenterDidDisappear(library: LibraryStore, modelContext: ModelContext) {
        isPresenterDetached = true
        guard let pending = pendingChoice else {
            return
        }

        subscribe(
            candidate: pending.choice.primary,
            for: pending,
            library: library,
            modelContext: modelContext
        )
    }

    private func resolveAndSubscribe(
        result: DirectoryPodcastResult,
        library: LibraryStore,
        modelContext: ModelContext,
        onSubscribed: @escaping () -> Void
    ) async {
        do {
            let candidates = await enrichedCandidates(for: result)
            guard !candidates.isEmpty else {
                subscribingResultID = nil
                errorMessage = "The directory did not provide an RSS feed for this podcast."
                return
            }
            let resolution = try await resolver.resolve(candidates: candidates)
            switch resolution {
            case .subscribe(let resolved):
                await subscribeDirectly(
                    feedURLString: resolved.candidate.feedURL.absoluteString,
                    library: library,
                    modelContext: modelContext,
                    onSubscribed: onSubscribed
                )
            case .choice(let choice):
                if isPresenterDetached {
                    await subscribeDirectly(
                        feedURLString: choice.primary.candidate.feedURL.absoluteString,
                        library: library,
                        modelContext: modelContext,
                        onSubscribed: onSubscribed
                    )
                } else {
                    subscribingResultID = nil
                    pendingChoice = PendingChoice(result: result, choice: choice)
                }
            }
        } catch is CancellationError {
            subscribingResultID = nil
        } catch {
            subscribingResultID = nil
            errorMessage = error.localizedDescription
        }
    }

    private func subscribeDirectly(
        feedURLString: String,
        library: LibraryStore,
        modelContext: ModelContext,
        onSubscribed: @escaping () -> Void
    ) async {
        defer {
            subscribingResultID = nil
        }
        do {
            try await library.subscribe(to: feedURLString, modelContext: modelContext)
            onSubscribed()
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Resolution applies to every candidate the merged result carries;
    /// Apple-only results with an Apple ID get one fill-in lookup, and
    /// a failed lookup quietly keeps the Apple candidates.
    private func enrichedCandidates(for result: DirectoryPodcastResult) async -> [DirectoryFeedCandidate] {
        var candidates = result.feedCandidates
        if candidates.isEmpty, let feedURL = result.feedURL {
            candidates = [DirectoryFeedCandidate(source: .apple, feedURL: feedURL)]
        }
        guard result.isAppleLookupEnrichable, let appleID = result.appleID else {
            return candidates
        }
        guard let enrichment = try? await directoryService.lookup(appleID: appleID) else {
            return candidates
        }
        return candidates + enrichment.feedCandidates
    }
}
