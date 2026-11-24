import SwiftUI

struct PodcastPreviewContent: View {
    let header: PodcastPreviewHeader
    let state: PodcastPreviewStore.State
    @Binding var selectedFeedID: String?
    let isInLibrary: Bool
    let isExpanded: Bool
    let onClose: (() -> Void)?
    let onRetry: () -> Void

    var body: some View {
        let showsFacts = header.title != nil || !isFailed
        if showsFacts || onClose != nil {
            PodcastPreviewHeaderView(header: header, showsFacts: showsFacts, isInLibrary: isInLibrary, onClose: onClose)
        }

        switch state {
        case .loading:
            PodcastPreviewLoadingContent()
        case .loaded(let feeds):
            PodcastPreviewLoadedContent(
                feeds: feeds,
                selectedFeedID: $selectedFeedID,
                isInLibrary: isInLibrary,
                isExpanded: isExpanded
            )
        case .failed(let failure):
            PodcastPreviewFailureView(failure: failure, onRetry: onRetry)
        }
    }

    private var isFailed: Bool {
        if case .failed = state {
            return true
        }
        return false
    }
}
