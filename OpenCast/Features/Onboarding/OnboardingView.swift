import OpenCastCore
import SwiftData
import SwiftUI

struct OnboardingView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var selectedPage = OnboardingPage.welcome
    @State private var popularStore: PopularPodcastsStore
    @State private var subscriptionErrorMessage: String?
    @State private var subscribingFeedURLString: String?

    init(discoveryService: any PodcastDiscoveryService) {
        _popularStore = State(initialValue: PopularPodcastsStore(discoveryService: discoveryService))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TabView(selection: $selectedPage) {
                    OnboardingWelcomePage()
                        .tag(OnboardingPage.welcome)

                    OnboardingOPMLImportPage()
                        .tag(OnboardingPage.importOPML)

                    OnboardingPopularPodcastsPage(
                        store: popularStore,
                        activePodcastIDs: appModel.library.activePodcastIDs,
                        subscribingFeedURLString: subscribingFeedURLString,
                        subscriptionErrorMessage: subscriptionErrorMessage,
                        onSubscribe: subscribeToSuggestion
                    )
                    .tag(OnboardingPage.popular)
                }
                .tabViewStyle(.page)

                OnboardingControlsView(
                    page: selectedPage,
                    canGoBack: selectedPage.previous != nil,
                    onBack: goBack,
                    onPrimary: performPrimaryAction
                )
                .padding()
                .background(.background)
            }
            .navigationTitle("Setup")
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled(!appModel.onboardingState.isCompleted)
        .accessibilityIdentifier("Onboarding")
    }

    private func goBack() {
        guard let previous = selectedPage.previous else {
            return
        }

        withAnimation(.bouncy) {
            selectedPage = previous
        }
    }

    private func performPrimaryAction() {
        guard let next = selectedPage.next else {
            completeOnboarding()
            return
        }

        withAnimation(.bouncy) {
            selectedPage = next
        }
    }

    private func completeOnboarding() {
        appModel.onboardingState.markCompleted(modelContext: modelContext)
        dismiss()
    }

    private func subscribeToSuggestion(_ result: DirectoryPodcastResult) {
        guard let feedURLString = result.feedURLString,
              subscribingFeedURLString == nil
        else {
            return
        }

        Task {
            await subscribe(to: feedURLString)
        }
    }

    private func subscribe(to feedURLString: String) async {
        subscriptionErrorMessage = nil
        subscribingFeedURLString = feedURLString
        defer {
            subscribingFeedURLString = nil
        }

        do {
            try await appModel.library.subscribe(to: feedURLString, modelContext: modelContext)
        } catch is CancellationError {
        } catch {
            subscriptionErrorMessage = error.localizedDescription
        }
    }
}
