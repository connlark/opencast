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
    let onClose: () -> Void
    let onRetry: () -> Void
    let onSubscribe: () -> Void
    let onGoToShow: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    PodcastPreviewContent(
                        header: header,
                        state: state,
                        selectedFeedID: $selectedFeedID,
                        isInLibrary: isInLibrary,
                        listsEveryEpisode: true,
                        onRetry: onRetry
                    )
                }
                .padding(.horizontal, 22)
                .padding(.top, 6)
            }
            .scrollBounceBehavior(.basedOnSize)
            .safeAreaBar(edge: .top) {
                Button("Close", systemImage: "xmark", role: .close, action: onClose)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                    .accessibilityIdentifier("Podcast Preview Close")
                    .padding(.top, 20)
                    .padding(.trailing, 22)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            // The automatic style draws no edge effect under a sheet's top bar.
            .scrollEdgeEffectStyle(.soft, for: .top)
            .mask {
                VStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 20)
                }
                .ignoresSafeArea()
            }

            // Under the page, not on a bottom bar: rows scrolled under a bar show
            // through behind the buttons, whatever the edge style.
            if action != nil || sample != nil {
                PodcastPreviewActionBar(
                    action: action,
                    sample: sample,
                    failureMessage: subscribeFailureMessage,
                    onSubscribe: onSubscribe,
                    onGoToShow: onGoToShow
                )
                .padding(.top, 12)
            }
        }
        // On the glass sheet the standard styles render vibrant, and the swap to the
        // opaque large sheet changes their brightness in one frame.
        .environment(\.backgroundMaterial, nil)
    }
}

#Preview("Loaded") {
    PodcastPreviewPreviewSamples.sheet(header: .signal, state: .loaded(.signal), action: .subscribe)
}

#Preview("Stopped") {
    PodcastPreviewPreviewSamples.sheet(header: .signalPath, state: .loaded(.signalPath), action: .subscribe)
}

#Preview("Large") {
    PodcastPreviewPreviewSamples.sheet(header: .signal, state: .loaded(.signal), action: .subscribe, detent: .large)
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
