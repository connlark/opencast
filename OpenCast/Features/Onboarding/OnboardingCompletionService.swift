import SwiftData

enum OnboardingCompletionService {
    enum Outcome {
        case completed
        case needsSampleConfirmation
    }

    static func finish(
        after addFlow: DirectorySubscriptionFlowStore,
        library: LibraryStore,
        onboardingState: OnboardingStateStore,
        modelContext: ModelContext
    ) async throws -> Outcome {
        await addFlow.waitForCurrentSubscription()
        try Task.checkCancellation()
        guard !library.activePodcastIDs.isEmpty else {
            return .needsSampleConfirmation
        }
        try markCompleted(onboardingState: onboardingState, modelContext: modelContext)
        return .completed
    }

    private static func markCompleted(
        onboardingState: OnboardingStateStore,
        modelContext: ModelContext
    ) throws {
        guard onboardingState.markCompleted(modelContext: modelContext) else {
            throw OnboardingCompletionError(
                message: onboardingState.lastErrorMessage ?? "Unable to complete onboarding."
            )
        }
    }

    static func subscribeToFallbackAndComplete(
        library: LibraryStore,
        onboardingState: OnboardingStateStore,
        modelContext: ModelContext
    ) async throws {
        try await library.subscribe(
            to: OpenCastConstants.thisAmericanLifeFeedURL,
            modelContext: modelContext
        )
        try markCompleted(onboardingState: onboardingState, modelContext: modelContext)
    }
}
