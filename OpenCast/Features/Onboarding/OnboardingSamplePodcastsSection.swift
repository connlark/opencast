import OpenCastCore
import SwiftUI

struct OnboardingSamplePodcastsSection: View {
    let activePodcastIDs: Set<String>
    let isSubscribing: Bool
    let subscribingResultID: String?
    let onSubscribe: (DirectoryPodcastResult) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sample Podcasts")
                .font(.headline)
                .foregroundStyle(.primary)

            VStack(spacing: 0) {
                ForEach(Array(OpenCastSamplePodcastSuggestions.all.enumerated()), id: \.element.id) { index, result in
                    PopularPodcastSuggestionRow(
                        result: result,
                        isSubscribed: isSubscribed(result),
                        isSubscribing: result.id == subscribingResultID,
                        isDisabled: isSubscribeDisabled(for: result),
                        onSubscribe: { onSubscribe(result) }
                    )

                    if index < OpenCastSamplePodcastSuggestions.all.count - 1 {
                        Divider()
                            .padding(.leading, 64)
                    }
                }
            }
            .padding(12)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
        }
    }

    private func isSubscribed(_ result: DirectoryPodcastResult) -> Bool {
        result.isSubscribed(activePodcastIDs: activePodcastIDs)
    }

    private func isSubscribeDisabled(for result: DirectoryPodcastResult) -> Bool {
        isSubscribing || !result.canResolveFeed || isSubscribed(result)
    }
}
