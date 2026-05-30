import OpenCastCore
import SwiftUI

struct PopularPodcastSuggestionRow: View {
    let result: DirectoryPodcastResult
    let isSubscribed: Bool
    let isSubscribing: Bool
    let isDisabled: Bool
    let onSubscribe: () -> Void

    var body: some View {
        DirectoryPodcastResultRow(result: result) {
            if isSubscribing {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Subscribing")
            } else if isSubscribed {
                Label("Subscribed", systemImage: "checkmark")
                    .foregroundStyle(.secondary)
            } else {
                Button("Subscribe", systemImage: "plus", action: onSubscribe)
                    .buttonStyle(.glass)
                    .disabled(isDisabled)
            }
        }
        .accessibilityElement(children: .contain)
    }
}
