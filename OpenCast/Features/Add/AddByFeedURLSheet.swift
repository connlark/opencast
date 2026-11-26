import OpenCastCore
import SwiftData
import SwiftUI

struct AddByFeedURLSheet: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    @State private var text: String
    @State private var request: PodcastPreviewRequest?
    @State private var rejectedText: String?
    @State private var offersPaste = false
    @State private var previewStore: PodcastPreviewStore
    @State private var addFlow: DirectorySubscriptionFlowStore
    @State private var navigationBarHeight = 56.0
    @State private var contentHeight = 82.0
    @State private var actionBarHeight = 0.0
    @FocusState private var isFieldFocused: Bool

    let onClose: () -> Void
    let onGoToShow: (String) -> Void

    init(
        directoryService: any PodcastDirectoryService,
        resolver: DirectoryFeedCandidateResolver,
        knownPodcasts: KnownPodcastsStore,
        onClose: @escaping () -> Void,
        onGoToShow: @escaping (String) -> Void
    ) {
        let text = OpenCastConstants.addByFeedURLInitialText
        _text = State(initialValue: text)
        _request = State(initialValue: Self.request(for: text))
        _previewStore = State(
            initialValue: PodcastPreviewStore(directoryService: directoryService, resolver: resolver, knownPodcasts: knownPodcasts)
        )
        _addFlow = State(
            initialValue: DirectorySubscriptionFlowStore(
                directoryService: directoryService,
                resolver: resolver,
                knownPodcasts: knownPodcasts
            )
        )
        self.onClose = onClose
        self.onGoToShow = onGoToShow
    }

    var body: some View {
        let isTakenUp = isRequestTakenUp
        let state = isTakenUp ? previewStore.state : .loading
        let isInLibrary = isTakenUp && libraryFeedURL != nil
        let action = request.flatMap { presenter.action(for: $0, state: state, isInLibrary: isInLibrary) }

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    AddByFeedURLField(
                        text: $text,
                        isFocused: $isFieldFocused,
                        offersPaste: offersPaste,
                        onSubmit: openTypedAddress,
                        onPaste: openPastedAddress
                    )
                    .disabled(addFlow.isBusy)

                    if rejectedText == text {
                        Text("That doesn’t look like a feed URL.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if let request {
                        VStack(alignment: .leading, spacing: 10) {
                            PodcastPreviewContent(
                                header: PodcastPreviewHeader(
                                    request: request,
                                    podcast: isTakenUp ? previewStore.displayedFeed?.candidate.podcast : nil
                                ),
                                state: state,
                                selectedFeedID: $previewStore.selectedFeedID,
                                isInLibrary: isInLibrary,
                                listsEveryEpisode: false,
                                onRetry: retry
                            )
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 20)
                .onGeometryChange(for: Double.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .onGeometryChange(for: Double.self) { $0.safeAreaInsets.top } action: { inset in
                // As the keyboard comes in, the sheet lays its content out once at zero
                // height. A detent that follows that inset moves during the keyboard's
                // animation, and the sheet comes to rest behind the keyboard.
                if inset > 0 {
                    navigationBarHeight = inset
                }
            }
            .safeAreaBar(edge: .bottom) {
                if let action {
                    PodcastPreviewActionBar(
                        action: action,
                        sample: isTakenUp ? previewStore.displayedFeed?.sampleEpisode : nil,
                        failureMessage: subscribeFailureMessage,
                        onSubscribe: subscribe,
                        onGoToShow: goToShow
                    )
                    .onGeometryChange(for: Double.self) { $0.size.height } action: { actionBarHeight = $0 }
                }
            }
            .navigationTitle("Add by Feed URL")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onClose)
                }
            }
        }
        .presentationDetents([.height(navigationBarHeight + contentHeight + (action == nil ? 0 : actionBarHeight))])
        .presentationBackground(.background)
        .task(id: request?.id) {
            if let request {
                await previewStore.load(request)
            }
        }
        .task {
            offersPaste = await AddPodcastClipboardReader.clipboardProbablyHasWebURL()
        }
        .onChange(of: text) {
            withdrawEditedAddress()
        }
        .onAppear(perform: focusEmptyField)
    }

    private var presenter: PodcastPreviewPresenter {
        PodcastPreviewPresenter(addFlow: addFlow, onSubscribed: {}, afterSubscribe: .offersGoToShow(onGoToShow))
    }

    private var isRequestTakenUp: Bool {
        request != nil && previewStore.request == request
    }

    private var libraryFeedURL: String? {
        previewStore.libraryFeedURL(activePodcastIDs: appModel.library.activePodcastIDs)
    }

    private var subscribeFailureMessage: String? {
        guard let failure = addFlow.failure, failure.addID == request?.id else {
            return nil
        }
        return failure.message
    }

    private static func request(for text: String) -> PodcastPreviewRequest? {
        PodcastFeedURLDetector.openableFeedURL(from: text).map { PodcastPreviewRequest(subject: .feedURL($0)) }
    }

    private func focusEmptyField() {
        isFieldFocused = request == nil
    }

    private func openTypedAddress() {
        guard let request = Self.request(for: text) else {
            rejectedText = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
            return
        }
        isFieldFocused = false
        self.request = request
    }

    private func openPastedAddress(_ string: String) {
        text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        openTypedAddress()
    }

    private func withdrawEditedAddress() {
        guard case .feedURL(let openedURL) = request?.subject,
              openedURL != PodcastFeedURLDetector.openableFeedURL(from: text)
        else {
            return
        }
        request = nil
    }

    private func retry() {
        if let request {
            self.request = PodcastPreviewRequest(subject: request.subject)
        }
    }

    private func subscribe() {
        guard isRequestTakenUp else {
            return
        }
        previewStore.subscribe(through: addFlow, library: appModel.library, modelContext: modelContext)
    }

    private func goToShow() {
        guard isRequestTakenUp, let libraryFeedURL else {
            return
        }
        onGoToShow(libraryFeedURL)
    }
}
