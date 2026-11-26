import SwiftUI

struct PodcastPreviewContent: View {
    let header: PodcastPreviewHeader
    let state: PodcastPreviewStore.State
    @Binding var selectedFeedID: String?
    let isInLibrary: Bool
    let listsEveryEpisode: Bool
    let onRetry: () -> Void

    var body: some View {
        let showsFacts = header.title != nil || !isFailed
        if showsFacts {
            PodcastPreviewHeaderView(header: header, isInLibrary: isInLibrary)
        }

        switch state {
        case .loading:
            PodcastPreviewLoadingContent()
        case .loaded(let feeds):
            PodcastPreviewLoadedContent(
                feeds: feeds,
                selectedFeedID: $selectedFeedID,
                isInLibrary: isInLibrary,
                listsEveryEpisode: listsEveryEpisode
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
