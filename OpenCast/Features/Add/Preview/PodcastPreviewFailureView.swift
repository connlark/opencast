import SwiftUI

struct PodcastPreviewFailureView: View {
    let failure: PodcastPreviewFailure
    let onRetry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(failure.title, systemImage: failure.systemImage)
        } description: {
            Text(failure.message)
        } actions: {
            Button("Try Again", systemImage: "arrow.clockwise", action: onRetry)
                .buttonStyle(.glass)
        }
    }
}
