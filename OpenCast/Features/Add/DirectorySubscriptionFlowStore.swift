import Foundation
import Observation
import OpenCastCore
import SwiftData

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
        // Unscoped so the subscription finishes if the presenting sheet disappears.
        subscriptionTask = Task {
            await resolveAndSubscribe(
                result: result,
                library: library,
                modelContext: modelContext,
                onSubscribed: onSubscribed
            )
        }
    }

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
                candidate: candidate,
                library: library,
                modelContext: modelContext,
                onSubscribed: onSubscribed
            )
        }
    }

    func dismissChoice() {
        pendingChoice = nil
    }

    /// Call only once the presenter is gone for good: from then on every feed choice,
    /// pending or still resolving, subscribes to its recommended primary candidate.
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
                    candidate: resolved,
                    library: library,
                    modelContext: modelContext,
                    onSubscribed: onSubscribed
                )
            case .choice(let choice):
                if isPresenterDetached {
                    await subscribeDirectly(
                        candidate: choice.primary,
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
        candidate: ResolvedFeedCandidate,
        library: LibraryStore,
        modelContext: ModelContext,
        onSubscribed: @escaping () -> Void
    ) async {
        defer {
            subscribingResultID = nil
        }
        do {
            try await library.subscribe(prepared: candidate.preparedFeed(), modelContext: modelContext)
            onSubscribed()
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }

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
