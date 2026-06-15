import OpenCastCore
import SwiftData
import SwiftUI

struct OnboardingView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    let onCompleted: () -> Void

    @State private var selectedPage = OnboardingPage.welcome
    @State private var selectedAddMode = AddPodcastMode.search
    @State private var feedURLString: String
    @State private var searchStore: PodcastSearchStore
    @State private var subscriptionErrorMessage: String?
    @State private var subscribingFeedURLString: String?
    @State private var clipboardErrorMessage: String?
    @State private var isSampleConfirmationPresented = false
    @FocusState private var focusedField: OnboardingFocusedField?

    init(
        directoryService: any PodcastDirectoryService,
        onCompleted: @escaping () -> Void
    ) {
        self.onCompleted = onCompleted
        _feedURLString = State(initialValue: OpenCastConstants.addPodcastInitialFeedURL)
        _searchStore = State(initialValue: PodcastSearchStore(directoryService: directoryService))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TabView(selection: $selectedPage) {
                    OnboardingWelcomePage()
                        .tag(OnboardingPage.welcome)

                    OnboardingOPMLImportPage()
                        .tag(OnboardingPage.importOPML)

                    OnboardingPodcastSetupPage(
                        searchStore: searchStore,
                        selectedMode: $selectedAddMode,
                        feedURLString: $feedURLString,
                        focusedField: $focusedField,
                        activePodcastIDs: appModel.library.activePodcastIDs,
                        subscribingFeedURLString: subscribingFeedURLString,
                        subscriptionErrorMessage: subscriptionErrorMessage,
                        clipboardErrorMessage: clipboardErrorMessage,
                        canSubscribeToRawFeed: canSubscribeToRawFeed,
                        onPaste: pasteFromClipboard,
                        onSubscribeRawFeed: subscribeToRawFeed,
                        onSubscribeSearchResult: subscribeToSearchResult,
                        onSubscribeSample: subscribeToSuggestion
                    )
                    .tag(OnboardingPage.podcastSetup)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                OnboardingPageIndicator(selectedPage: selectedPage)
                    .padding(.top, 6)
                    .padding(.bottom, 4)

                OnboardingControlsView(
                    page: selectedPage,
                    canGoBack: selectedPage.previous != nil,
                    isPrimaryDisabled: isSubscribing && selectedPage == .podcastSetup,
                    onBack: goBack,
                    onPrimary: performPrimaryAction
                )
                .padding()
                .background(.background)
                .confirmationDialog(
                    "Add This American Life?",
                    isPresented: $isSampleConfirmationPresented
                ) {
                    Button("Add This American Life", action: subscribeToFallbackAndComplete)
                    Button("Keep Choosing", role: .cancel) {}
                } message: {
                    Text("opencast will add This American Life so you can get acquainted with podcasts before choosing more shows.")
                }
            }
            .navigationTitle("Setup")
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled(!appModel.onboardingState.isCompleted)
        .onDisappear(perform: searchStore.cancelSearch)
        .accessibilityIdentifier("Onboarding")
    }

    private var isSubscribing: Bool {
        subscribingFeedURLString != nil
    }

    private var canSubscribeToRawFeed: Bool {
        !trimmedFeedURLString.isEmpty
    }

    private var trimmedFeedURLString: String {
        feedURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func goBack() {
        guard focusedField == nil else {
            focusedField = nil
            return
        }

        guard let previous = selectedPage.previous else {
            return
        }

        withAnimation(.bouncy) {
            selectedPage = previous
        }
    }

    private func performPrimaryAction() {
        guard focusedField == nil else {
            focusedField = nil
            return
        }

        guard let next = selectedPage.next else {
            finishOnboarding()
            return
        }

        withAnimation(.bouncy) {
            selectedPage = next
        }
    }

    private func finishOnboarding() {
        guard !OnboardingCompletionService.needsSampleConfirmation(
            activePodcastIDs: appModel.library.activePodcastIDs
        ) else {
            isSampleConfirmationPresented = true
            return
        }

        completeOnboarding()
    }

    private func completeOnboarding() {
        do {
            try OnboardingCompletionService.markCompleted(
                onboardingState: appModel.onboardingState,
                modelContext: modelContext
            )
            onCompleted()
        } catch {
            subscriptionErrorMessage = error.localizedDescription
        }
    }

    private func subscribeToSuggestion(_ result: DirectoryPodcastResult) {
        guard let feedURLString = result.feedURLString,
              !isSubscribing
        else {
            return
        }

        Task {
            await subscribe(to: feedURLString)
        }
    }

    private func subscribeToRawFeed() {
        guard canSubscribeToRawFeed, !isSubscribing else {
            return
        }

        clipboardErrorMessage = nil
        Task {
            await subscribe(to: trimmedFeedURLString)
        }
    }

    private func subscribeToSearchResult(_ result: DirectoryPodcastResult) {
        guard let feedURLString = result.feedURLString,
              !isSubscribing
        else {
            return
        }

        Task {
            await subscribe(to: feedURLString)
        }
    }

    private func pasteFromClipboard() {
        guard let copiedFeedURLString = AddPodcastClipboardReader.feedURLStringFromClipboard() else {
            clipboardErrorMessage = "Clipboard does not contain an HTTP podcast feed URL."
            return
        }

        feedURLString = copiedFeedURLString
        clipboardErrorMessage = nil
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

    private func subscribeToFallbackAndComplete() {
        guard !isSubscribing else {
            return
        }

        Task {
            await completeAfterFallbackSubscription()
        }
    }

    private func completeAfterFallbackSubscription() async {
        subscriptionErrorMessage = nil
        subscribingFeedURLString = OpenCastConstants.thisAmericanLifeFeedURL
        defer {
            subscribingFeedURLString = nil
        }

        do {
            try await OnboardingCompletionService.subscribeToFallbackAndComplete(
                library: appModel.library,
                onboardingState: appModel.onboardingState,
                modelContext: modelContext
            )
            onCompleted()
        } catch is CancellationError {
        } catch {
            subscriptionErrorMessage = error.localizedDescription
        }
    }
}
