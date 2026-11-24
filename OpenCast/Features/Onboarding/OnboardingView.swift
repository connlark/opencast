import OpenCastCore
import SwiftData
import SwiftUI

struct OnboardingView: View {
    private static let whisperModelInstallToastDuration: Duration = .seconds(4)

    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    let onCompleted: () -> Void

    @State private var selectedPage: OnboardingPage
    private let pages = OnboardingPage.allCases
    @State private var searchStore: PodcastSearchStore
    @State private var subscriptionFlow: DirectorySubscriptionFlowStore
    @State private var sheetDestination: SheetDestination?
    @State private var completionErrorMessage: String?
    @State private var isFinishing = false
    @State private var finishTask: Task<Void, Never>?
    @State private var isSubscribingToFallback = false
    @State private var isSampleConfirmationPresented = false
    @State private var importedNotificationFeedbackToken = 0
    @State private var announcedImportedNotificationID: Int?
    @State private var isWhisperModelInstallToastPresented = false
    @State private var whisperModelInstallToastFeedbackToken = 0
    @FocusState private var isSearchFieldFocused: Bool

    init(
        directoryService: any PodcastDirectoryService,
        directoryResolver: DirectoryFeedCandidateResolver = DirectoryFeedCandidateResolver(),
        knownPodcasts: KnownPodcastsStore,
        onCompleted: @escaping () -> Void
    ) {
        self.onCompleted = onCompleted
        _selectedPage = State(initialValue: .welcome)
        _searchStore = State(initialValue: PodcastSearchStore(directoryService: directoryService, knownPodcasts: knownPodcasts))
        _subscriptionFlow = State(
            initialValue: DirectorySubscriptionFlowStore(
                directoryService: directoryService,
                resolver: directoryResolver,
                knownPodcasts: knownPodcasts
            )
        )
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
                    isPrimaryBusy: isFinishing && selectedPage == pages.last,
                    addedShowCount: selectedPage == .podcastSetup ? appModel.library.activePodcastIDs.count : 0,
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
        .sheet(item: $sheetDestination) { destination in
            // Glass would let the Continue button behind the peek show through beside Subscribe.
            SheetDestinationView(destination: destination, onDismiss: dismissSheet)
                .presentationBackground(.background)
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
        .onChange(of: selectedPage, handlePageChange)
        .onChange(of: isSampleConfirmationPresented) { _, isPresented in
            if !isPresented, !isSubscribingToFallback {
                isFinishing = false
            }
        }
        .onChange(of: subscriptionFlow.pendingChoice?.id) { _, _ in
            presentHandedOffChoice()
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
                addFlow: subscriptionFlow,
                knownPodcasts: appModel.knownPodcasts,
                subscriptions: appModel.library.subscriptions,
                activePodcastIDs: appModel.library.activePodcastIDs,
                isSearchFieldFocused: $isSearchFieldFocused,
                onOpenResult: openResult,
                onOpenFeed: openFeed,
                onQuickAdd: quickAdd
            )
        case .transcriptionModelSetup:
            OnboardingTranscriptionModelSetupPage(
                selectedChoice: appModel.transcriptionModels.selectedChoice,
                modelState: appModel.transcriptionModels.state,
                onInstall: installTinyWhisperModel
            )
        case .notificationSetup:
            OnboardingNotificationSetupPage(
                completionErrorMessage: completionErrorMessage
            )
        }
    }

    private func goBack() {
        guard !isSearchFieldFocused else {
            isSearchFieldFocused = false
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
        guard !isSearchFieldFocused else {
            isSearchFieldFocused = false
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
        guard !isFinishing else {
            return
        }

        isFinishing = true
        finishTask = Task {
            await finishAfterAddInFlight()
        }
    }

    private func finishAfterAddInFlight() async {
        do {
            let outcome = try await OnboardingCompletionService.finish(
                after: subscriptionFlow,
                library: appModel.library,
                onboardingState: appModel.onboardingState,
                modelContext: modelContext
            )
            switch outcome {
            case .completed:
                completeResolvedOnboarding()
            case .needsSampleConfirmation:
                isSampleConfirmationPresented = true
            }
        } catch is CancellationError {
        } catch {
            completionErrorMessage = error.localizedDescription
            isFinishing = false
        }
    }

    private func cancelFinish() {
        finishTask?.cancel()
        finishTask = nil
        if !isSubscribingToFallback {
            isFinishing = false
        }
    }

    private func handlePageChange(from oldPage: OnboardingPage, to newPage: OnboardingPage) {
        if oldPage == pages.last {
            cancelFinish()
        }
        if oldPage == .podcastSetup {
            subscriptionFlow.presenterDidDisappear(library: appModel.library, modelContext: modelContext)
        }
        if newPage == .podcastSetup {
            subscriptionFlow.presenterDidAppear()
        }
    }

    private func openResult(_ result: DirectoryPodcastResult) {
        guard !subscriptionFlow.isBusy, result.canResolveFeed else {
            return
        }

        present(PodcastPreviewRequest(subject: .result(result)))
    }

    private func openFeed(_ feedURL: URL) {
        present(PodcastPreviewRequest(subject: .feedURL(feedURL)))
    }

    private func quickAdd(_ result: DirectoryPodcastResult) {
        isSearchFieldFocused = false
        subscriptionFlow.subscribe(
            to: result,
            library: appModel.library,
            modelContext: modelContext
        )
    }

    private func presentHandedOffChoice() {
        guard selectedPage == .podcastSetup, let request = subscriptionFlow.handOffChoice() else {
            return
        }

        present(request)
    }

    private func present(_ request: PodcastPreviewRequest) {
        isSearchFieldFocused = false
        sheetDestination = .podcastPreview(
            request,
            PodcastPreviewPresenter(addFlow: subscriptionFlow, onSubscribed: {}, afterSubscribe: .closesPeek)
        )
    }

    private func dismissSheet() {
        sheetDestination = nil
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
        } catch {
            return
        }

        guard !Task.isCancelled else {
            return
        }

        isWhisperModelInstallToastPresented = false
    }

    private func subscribeToFallbackAndComplete() {
        guard !isSubscribingToFallback else {
            return
        }

        isSubscribingToFallback = true
        isFinishing = true
        Task {
            await completeAfterFallbackSubscription()
        }
    }

    private func completeAfterFallbackSubscription() async {
        completionErrorMessage = nil
        defer {
            isSubscribingToFallback = false
        }

        do {
            try await OnboardingCompletionService.subscribeToFallbackAndComplete(
                library: appModel.library,
                onboardingState: appModel.onboardingState,
                modelContext: modelContext
            )
            completeResolvedOnboarding()
        } catch is CancellationError {
            isFinishing = false
        } catch {
            completionErrorMessage = error.localizedDescription
            isFinishing = false
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
        finishTask?.cancel()
        searchStore.cancelSearch()
        subscriptionFlow.presenterDidDisappear(
            library: appModel.library,
            modelContext: modelContext
        )
    }
}
