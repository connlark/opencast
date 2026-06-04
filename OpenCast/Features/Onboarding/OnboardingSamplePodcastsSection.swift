import OpenCastCore
import SwiftUI

struct OnboardingSamplePodcastsSection: View {
    let activePodcastIDs: Set<String>
    let subscribingFeedURLString: String?
    let onSubscribe: (DirectoryPodcastResult) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sample Podcasts")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                ForEach(Array(OpenCastSamplePodcastSuggestions.all.enumerated()), id: \.element.id) { index, result in
                    PopularPodcastSuggestionRow(
                        result: result,
                        isSubscribed: isSubscribed(result),
                        isSubscribing: isSubscribing(result),
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
            .glassEffect(.regular, in: .rect(cornerRadius: 22))
        }
    }

    private var isSubscribingAnyPodcast: Bool {
        subscribingFeedURLString != nil
    }

    private func isSubscribed(_ result: DirectoryPodcastResult) -> Bool {
        guard let feedURLString = result.feedURLString else {
            return false
        }

        let canonicalFeedURLString = URLCanonicalizer.canonicalString(forRawString: feedURLString)
        return activePodcastIDs.contains(canonicalFeedURLString)
    }

    private func isSubscribing(_ result: DirectoryPodcastResult) -> Bool {
        guard let feedURLString = result.feedURLString else {
            return false
        }

        return subscribingFeedURLString == feedURLString
    }

    private func isSubscribeDisabled(for result: DirectoryPodcastResult) -> Bool {
        isSubscribingAnyPodcast || result.feedURLString == nil || isSubscribed(result)
    }
}
