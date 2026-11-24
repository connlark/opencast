struct PodcastPreviewPresenter {
    enum AfterSubscribe {
        case offersGoToShow((String) -> Void)
        case closesPeek
    }

    let addFlow: DirectorySubscriptionFlowStore
    let onSubscribed: () -> Void
    let afterSubscribe: AfterSubscribe

    func action(
        for request: PodcastPreviewRequest,
        state: PodcastPreviewStore.State,
        isInLibrary: Bool
    ) -> PodcastPreviewActionBar.Action? {
        if isInLibrary {
            guard case .offersGoToShow = afterSubscribe else {
                return nil
            }
            return .goToShow
        }
        return switch state {
        case .loading: .waiting
        case .loaded: addFlow.canSubscribe(request) ? .subscribe : .waiting
        case .failed: nil
        }
    }
}
