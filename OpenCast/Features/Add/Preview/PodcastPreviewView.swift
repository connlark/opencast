import OpenCastCore
import SwiftUI

struct PodcastPreviewView: View {
    let header: PodcastPreviewHeader
    let state: PodcastPreviewStore.State
    @Binding var selectedFeedID: String?
    let action: PodcastPreviewActionBar.Action?
    var sample: Episode?
    var subscribeFailureMessage: String?
    let isInLibrary: Bool
    let isExpanded: Bool
    let onClose: () -> Void
    let onRetry: () -> Void
    let onSubscribe: () -> Void
    let onGoToShow: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                PodcastPreviewContent(
                    header: header,
                    state: state,
                    selectedFeedID: $selectedFeedID,
                    isInLibrary: isInLibrary,
                    isExpanded: isExpanded,
                    onClose: onClose,
                    onRetry: onRetry
                )
            }
            .padding(.horizontal, 22)
            .padding(.top, 20)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaBar(edge: .bottom) {
            if action != nil || sample != nil {
                PodcastPreviewActionBar(
                    action: action,
                    sample: sample,
                    failureMessage: subscribeFailureMessage,
                    onSubscribe: onSubscribe,
                    onGoToShow: onGoToShow
                )
            }
        }
    }
}

#Preview("Loaded") {
    PodcastPreviewPreviewSamples.sheet(header: .signal, state: .loaded(.signal), action: .subscribe)
}

#Preview("Stopped") {
    PodcastPreviewPreviewSamples.sheet(header: .signalPath, state: .loaded(.signalPath), action: .subscribe)
}

#Preview("Expanded") {
    PodcastPreviewPreviewSamples.sheet(header: .signal, state: .loaded(.signal), action: .subscribe, isExpanded: true)
}

#Preview("Two feeds") {
    PodcastPreviewPreviewSamples.sheet(header: .longWayHome, state: .loaded(.longWayHome), action: .subscribe)
}

#Preview("Subscribed") {
    PodcastPreviewPreviewSamples.sheet(header: .signal, state: .loaded(.signal), action: .goToShow, isInLibrary: true)
}

#Preview("Loading") {
    PodcastPreviewPreviewSamples.sheet(header: .signal, state: .loading, action: .waiting)
}

#Preview("Offline") {
    PodcastPreviewPreviewSamples.sheet(header: .signal, state: .failed(.offline))
}

#Preview("Didn’t respond") {
    PodcastPreviewPreviewSamples.sheet(header: .signal, state: .failed(.noResponse(host: "feeds.northfield.example.com")))
}

#Preview("Returned an error") {
    PodcastPreviewPreviewSamples.sheet(header: .signal, state: .failed(.errorResponse(host: "feeds.northfield.example.com")))
}

#Preview("Not a podcast feed") {
    PodcastPreviewPreviewSamples.sheet(header: .signal, state: .failed(.notAPodcastFeed(host: "feeds.northfield.example.com")))
}

#Preview("No RSS feed") {
    PodcastPreviewPreviewSamples.sheet(header: .signal, state: .failed(.noFeed))
}
