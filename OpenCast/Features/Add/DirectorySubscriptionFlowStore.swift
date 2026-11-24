import Foundation
import Observation
import OpenCastCore
import SwiftData

@Observable
final class DirectorySubscriptionFlowStore {
    struct PendingChoice: Identifiable {
        let id: UUID
        let result: DirectoryPodcastResult
        let choice: DirectoryFeedChoice
    }

    struct Failure {
        let addID: UUID
        let showTitle: String
        let message: String
    }

    private struct Add {
        let id: UUID
        let showID: String
        let showTitle: String
        let key: KnownPodcastsStore.Key
        let token: UUID
        let generation: Int
        var isAwaitingChoice = false
    }

    private(set) var subscribingResultID: String?
    private(set) var pendingChoice: PendingChoice?
    private(set) var failure: Failure?
    private(set) var addedShowIDs: Set<String> = []
    private var add: Add?

    @ObservationIgnored private let directoryService: any PodcastDirectoryService
    @ObservationIgnored private let resolver: DirectoryFeedCandidateResolver
    @ObservationIgnored private let knownPodcasts: KnownPodcastsStore
    @ObservationIgnored private var subscriptionTask: Task<Void, Never>?
    @ObservationIgnored private var isPresenterDetached = false

    init(
        directoryService: any PodcastDirectoryService,
        resolver: DirectoryFeedCandidateResolver,
        knownPodcasts: KnownPodcastsStore
    ) {
        self.directoryService = directoryService
        self.resolver = resolver
        self.knownPodcasts = knownPodcasts
    }

    var isBusy: Bool {
        add != nil
    }

    func clearError() {
        failure = nil
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
        guard add == nil, result.canResolveFeed,
              let token = knownPodcasts.beginAdding(result.knownPodcastKey)
        else {
            return
        }

        let add = Add(
            id: UUID(),
            showID: result.id,
            showTitle: result.title,
            key: result.knownPodcastKey,
            token: token,
            generation: library.captureWriteGeneration()
        )
        begin(add)
        // Unscoped so the subscription finishes if the presenting sheet disappears.
        subscriptionTask = Task {
            await resolveAndSubscribe(
                result: result,
                add: add,
                library: library,
                modelContext: modelContext,
                onSubscribed: onSubscribed
            )
        }
    }

    /// From here the peek owns the choice: dismissing the presenter no longer subscribes it.
    func handOffChoice() -> PodcastPreviewRequest? {
        guard let pending = pendingChoice else {
            return nil
        }
        pendingChoice = nil
        return PodcastPreviewRequest(id: pending.id, subject: .resolvedChoice(pending.result, pending.choice))
    }

    func releaseHandedOffChoice(_ requestID: UUID) {
        if let add, add.id == requestID, add.isAwaitingChoice {
            finish(add)
        }
    }

    func canSubscribe(_ request: PodcastPreviewRequest) -> Bool {
        guard let add else {
            return !knownPodcasts.isAdding(request.knownPodcastKey)
        }
        return add.id == request.id && add.isAwaitingChoice
    }

    func subscribe(
        previewed candidate: ResolvedFeedCandidate,
        request: PodcastPreviewRequest,
        library: LibraryStore,
        modelContext: ModelContext,
        onSubscribed: @escaping () -> Void = {}
    ) {
        if let add {
            guard add.id == request.id, add.isAwaitingChoice else {
                return
            }
            write(candidate, for: add, library: library, modelContext: modelContext, onSubscribed: onSubscribed)
            return
        }
        guard let token = knownPodcasts.beginAdding(request.knownPodcastKey) else {
            return
        }

        let add = Add(
            id: request.id,
            showID: request.showID,
            showTitle: PodcastPreviewHeader(request: request, podcast: candidate.podcast).title ?? candidate.podcast.title,
            key: request.knownPodcastKey,
            token: token,
            generation: library.captureWriteGeneration()
        )
        write(candidate, for: add, library: library, modelContext: modelContext, onSubscribed: onSubscribed)
    }

    func presenterDidDisappear(library: LibraryStore, modelContext: ModelContext) {
        isPresenterDetached = true
        if let pending = pendingChoice {
            pendingChoice = nil
            if let add, add.id == pending.id, add.isAwaitingChoice {
                write(pending.choice.primary, for: add, library: library, modelContext: modelContext, onSubscribed: {})
            }
        } else if let add, add.isAwaitingChoice {
            finish(add)
        }
    }

    func presenterDidAppear() {
        isPresenterDetached = false
    }

    private func begin(_ add: Add) {
        self.add = add
        failure = nil
        subscribingResultID = add.showID
    }

    private func finish(_ add: Add) {
        knownPodcasts.finishAdding(add.token)
        guard self.add?.id == add.id else {
            return
        }
        self.add = nil
        subscribingResultID = nil
    }

    private func fail(_ add: Add, message: String) {
        failure = Failure(addID: add.id, showTitle: add.showTitle, message: message)
        finish(add)
    }

    private func resolveAndSubscribe(
        result: DirectoryPodcastResult,
        add: Add,
        library: LibraryStore,
        modelContext: ModelContext,
        onSubscribed: @escaping () -> Void
    ) async {
        do {
            let candidates = try await result.enrichedFeedCandidates(using: directoryService)
            knownPodcasts.learn(Set(candidates.map(\.canonicalFeedURLString)), about: add.key)
            guard !candidates.isEmpty else {
                fail(add, message: "The directory did not provide an RSS feed for this podcast.")
                return
            }
            let resolution = try await resolver.resolve(candidates: candidates)
            knownPodcasts.learn(resolution.readFeedURLs, about: add.key)
            guard library.captureWriteGeneration() == add.generation else {
                finish(add)
                return
            }
            switch resolution.outcome {
            case .subscribe(let resolved):
                await subscribeDirectly(resolved, for: add, library: library, modelContext: modelContext, onSubscribed: onSubscribed)
            case .choice(let choice):
                if isPresenterDetached {
                    await subscribeDirectly(choice.primary, for: add, library: library, modelContext: modelContext, onSubscribed: onSubscribed)
                } else {
                    self.add?.isAwaitingChoice = true
                    subscribingResultID = nil
                    pendingChoice = PendingChoice(id: add.id, result: result, choice: choice)
                }
            }
        } catch is CancellationError {
            finish(add)
        } catch {
            fail(add, message: error.localizedDescription)
        }
    }

    private func write(
        _ candidate: ResolvedFeedCandidate,
        for add: Add,
        library: LibraryStore,
        modelContext: ModelContext,
        onSubscribed: @escaping () -> Void
    ) {
        var add = add
        add.isAwaitingChoice = false
        begin(add)
        subscriptionTask = Task {
            await subscribeDirectly(candidate, for: add, library: library, modelContext: modelContext, onSubscribed: onSubscribed)
        }
    }

    private func subscribeDirectly(
        _ candidate: ResolvedFeedCandidate,
        for add: Add,
        library: LibraryStore,
        modelContext: ModelContext,
        onSubscribed: @escaping () -> Void
    ) async {
        defer {
            finish(add)
        }
        guard knownPodcasts.claimWrite(add.token) else {
            return
        }
        guard library.activePodcastIDs.isDisjoint(with: knownPodcasts.feedURLs(for: add.key)) else {
            addedShowIDs.insert(add.showID)
            onSubscribed()
            return
        }
        do {
            try await library.subscribe(
                prepared: candidate.preparedFeed(),
                modelContext: modelContext,
                generation: add.generation
            )
            addedShowIDs.insert(add.showID)
            onSubscribed()
        } catch is CancellationError {
        } catch {
            failure = Failure(addID: add.id, showTitle: add.showTitle, message: error.localizedDescription)
        }
    }
}
