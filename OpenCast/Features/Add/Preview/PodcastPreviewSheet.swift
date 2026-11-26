import OpenCastCore
import SwiftData
import SwiftUI

struct PodcastPreviewSheet: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    @State private var store: PodcastPreviewStore
    @State private var loadAttempt = 0

    let request: PodcastPreviewRequest
    let presenter: PodcastPreviewPresenter
    let onClose: () -> Void

    init(
        request: PodcastPreviewRequest,
        directoryService: any PodcastDirectoryService,
        resolver: DirectoryFeedCandidateResolver,
        knownPodcasts: KnownPodcastsStore,
        presenter: PodcastPreviewPresenter,
        onClose: @escaping () -> Void
    ) {
        _store = State(
            initialValue: PodcastPreviewStore(
                directoryService: directoryService,
                resolver: resolver,
                knownPodcasts: knownPodcasts
            )
        )
        self.request = request
        self.presenter = presenter
        self.onClose = onClose
    }

    var body: some View {
        let isInLibrary = store.libraryFeedURL(activePodcastIDs: appModel.library.activePodcastIDs) != nil
        let failure = presenter.addFlow.failure

        PodcastPreviewView(
            header: PodcastPreviewHeader(request: request, podcast: store.displayedFeed?.candidate.podcast),
            state: store.state,
            selectedFeedID: $store.selectedFeedID,
            action: presenter.action(for: request, state: store.state, isInLibrary: isInLibrary),
            sample: store.displayedFeed?.sampleEpisode,
            subscribeFailureMessage: failure?.addID == request.id ? failure?.message : nil,
            isInLibrary: isInLibrary,
            onClose: onClose,
            onRetry: retry,
            onSubscribe: subscribe,
            onGoToShow: goToShow
        )
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task(id: loadAttempt) {
            await store.load(request)
        }
        .onDisappear(perform: releaseHandedOffChoice)
    }

    private func retry() {
        loadAttempt += 1
    }

    private func goToShow() {
        guard case .offersGoToShow(let goToShow) = presenter.afterSubscribe,
              let feedURL = store.libraryFeedURL(activePodcastIDs: appModel.library.activePodcastIDs)
        else {
            return
        }
        goToShow(feedURL)
    }

    private func subscribe() {
        store.subscribe(
            through: presenter.addFlow,
            library: appModel.library,
            modelContext: modelContext,
            onSubscribed: subscriptionLanded
        )
    }

    private func subscriptionLanded() {
        presenter.onSubscribed()
        if case .closesPeek = presenter.afterSubscribe {
            onClose()
        }
    }

    private func releaseHandedOffChoice() {
        presenter.addFlow.releaseHandedOffChoice(request.id)
    }
}
