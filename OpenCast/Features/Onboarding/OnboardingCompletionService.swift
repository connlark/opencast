import SwiftData

enum OnboardingCompletionService {
    static func needsSampleConfirmation(activePodcastIDs: Set<String>) -> Bool {
        activePodcastIDs.isEmpty
    }

    static func markCompleted(
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
