import OpenCastCore
import SwiftData
import SwiftUI

struct OnboardingView: View {
    private static let whisperModelInstallToastDuration: Duration = .seconds(4)

    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    let onCompleted: () -> Void

    @State private var selectedPage: OnboardingPage
    /// Every case shows, in declaration order. Decision 4 revision
    /// (2026-07-07): the Tiny Whisper step always shows. Whisper is
    /// load-bearing — it's the ad-free-pass engine on devices without
    /// background GPU (decision 1 amendment) and the fallback everywhere
    /// else — so onboarding fronts its download for everyone. Apple speech
    /// assets install lazily when a surface first needs them.
    private let pages = OnboardingPage.allCases
    @State private var selectedAddMode = AddPodcastMode.search
    @State private var feedURLString: String
    @State private var searchStore: PodcastSearchStore
    @State private var subscriptionErrorMessage: String?
    @State private var subscribingFeedURLString: String?
    @State private var clipboardErrorMessage: String?
    @State private var isSampleConfirmationPresented = false
    @State private var importedNotificationFeedbackToken = 0
    @State private var announcedImportedNotificationID: Int?
    @State private var isWhisperModelInstallToastPresented = false
    @State private var whisperModelInstallToastFeedbackToken = 0
    @FocusState private var focusedField: OnboardingFocusedField?

    init(
        directoryService: any PodcastDirectoryService,
        onCompleted: @escaping () -> Void
    ) {
        self.onCompleted = onCompleted
        _selectedPage = State(initialValue: .welcome)
        _feedURLString = State(initialValue: OpenCastConstants.addPodcastInitialFeedURL)
        _searchStore = State(initialValue: PodcastSearchStore(directoryService: directoryService))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TabView(selection: $selectedPage) {
                    ForEach(pages) { page in
                        pageView(for: page)
                            .tag(page)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                OnboardingPageIndicator(pages: pages, selectedPage: selectedPage)
                    .padding(.top, 6)
                    .padding(.bottom, 4)

                OnboardingControlsView(
                    page: selectedPage,
                    canGoBack: selectedPage.previous(in: pages) != nil,
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
            .background(.background)
            .navigationTitle("Setup")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) {
                if isWhisperModelInstallToastPresented || appModel.importedSubscriptionsNotification != nil {
                    OnboardingTopToastStack(
                        isWhisperModelInstallToastPresented: isWhisperModelInstallToastPresented,
                        importedSubscriptionsNotification: appModel.importedSubscriptionsNotification
                    )
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.bouncy, value: appModel.importedSubscriptionsNotification?.id)
            .animation(.bouncy, value: isWhisperModelInstallToastPresented)
        }
        .interactiveDismissDisabled(!appModel.onboardingState.isCompleted)
        .sensoryFeedback(.success, trigger: importedNotificationFeedbackToken)
        .sensoryFeedback(.success, trigger: whisperModelInstallToastFeedbackToken)
        .onChange(of: appModel.importedSubscriptionsNotification?.id) { _, notificationID in
            guard let notificationID,
                  let notification = appModel.importedSubscriptionsNotification
            else {
                return
            }

            importedNotificationFeedbackToken += 1
            announceImportedNotification(notification, id: notificationID)
        }
        .task(id: whisperModelInstallToastFeedbackToken) {
            await dismissWhisperModelInstallToastAfterDelay()
        }
        .onDisappear(perform: handleDisappear)
        .accessibilityIdentifier("Onboarding")
    }

    @ViewBuilder
    private func pageView(for page: OnboardingPage) -> some View {
        switch page {
        case .welcome:
            OnboardingWelcomePage()
        case .importOPML:
            OnboardingOPMLImportPage()
        case .podcastSetup:
            OnboardingPodcastSetupPage(
                searchStore: searchStore,
                selectedMode: $selectedAddMode,
                feedURLString: $feedURLString,
                focusedField: $focusedField,
                subscriptions: appModel.library.subscriptions,
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
        case .transcriptionModelSetup:
            OnboardingTranscriptionModelSetupPage(
                selectedChoice: appModel.transcriptionModels.selectedChoice,
                modelState: appModel.transcriptionModels.state,
                onInstall: installTinyWhisperModel
            )
        case .notificationSetup:
            OnboardingNotificationSetupPage(
                completionErrorMessage: subscriptionErrorMessage
            )
        }
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

        guard let previous = selectedPage.previous(in: pages) else {
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

        guard let next = selectedPage.next(in: pages) else {
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
            completeResolvedOnboarding()
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

    private func installTinyWhisperModel() {
        if appModel.transcriptionModels.selectedChoice != .fastTinyEnglish {
            guard appModel.setTranscriptionModelChoice(.fastTinyEnglish, modelContext: modelContext) else {
                return
            }
        }

        guard appModel.installTranscriptionModel() else {
            return
        }

        presentWhisperModelInstallToast()

        withAnimation(.bouncy) {
            selectedPage = .notificationSetup
        }
    }

    private func presentWhisperModelInstallToast() {
        whisperModelInstallToastFeedbackToken += 1
        isWhisperModelInstallToastPresented = true

        AccessibilityNotification.Announcement(
            WhisperModelInstallToast.accessibilityAnnouncement
        ).post()
    }

    private func dismissWhisperModelInstallToastAfterDelay() async {
        guard isWhisperModelInstallToastPresented else {
            return
        }

        do {
            try await Task.sleep(for: Self.whisperModelInstallToastDuration)
        } catch is CancellationError {
            return
        } catch {
            return
        }

        guard !Task.isCancelled else {
            return
        }

        isWhisperModelInstallToastPresented = false
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
            completeResolvedOnboarding()
        } catch is CancellationError {
        } catch {
            subscriptionErrorMessage = error.localizedDescription
        }
    }

    private func completeResolvedOnboarding() {
        onCompleted()
    }

    private func announceImportedNotification(_ notification: ImportedSubscriptionsNotification, id: Int) {
        guard announcedImportedNotificationID != id else {
            return
        }

        announcedImportedNotificationID = id
        AccessibilityNotification.Announcement(
            "\(notification.title). \(notification.detail)"
        ).post()
    }

    private func handleDisappear() {
        searchStore.cancelSearch()
    }
}
