import OpenCastCore
import SwiftUI

struct OnboardingPodcastSetupPage: View {
    @Bindable var searchStore: PodcastSearchStore
    @Binding var selectedMode: AddPodcastMode
    @Binding var feedURLString: String

    let focusedField: FocusState<OnboardingFocusedField?>.Binding
    let activePodcastIDs: Set<String>
    let subscribingFeedURLString: String?
    let subscriptionErrorMessage: String?
    let clipboardErrorMessage: String?
    let canSubscribeToRawFeed: Bool
    let onPaste: () -> Void
    let onSubscribeRawFeed: () -> Void
    let onSubscribeSearchResult: (DirectoryPodcastResult) -> Void
    let onSubscribeSample: (DirectoryPodcastResult) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Find Podcasts")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text("Search by name, paste an RSS feed URL, or start with a sample show.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .glassEffect(.regular, in: .rect(cornerRadius: 20))

                AddPodcastModePicker(selectedMode: $selectedMode)
                    .padding(4)
                    .glassEffect(.regular, in: .rect(cornerRadius: 24))

                switch selectedMode {
                case .rss:
                    OnboardingRSSFeedSection(
                        feedURLString: $feedURLString,
                        focusedField: focusedField,
                        isSubscribing: isSubscribing,
                        canSubscribe: canSubscribeToRawFeed,
                        onPaste: onPaste,
                        onSubscribe: onSubscribeRawFeed
                    )
                case .search:
                    OnboardingPodcastSearchSection(
                        store: searchStore,
                        focusedField: focusedField,
                        activePodcastIDs: activePodcastIDs,
                        subscribingFeedURLString: subscribingFeedURLString,
                        onSubscribe: onSubscribeSearchResult
                    )
                }

                OnboardingSamplePodcastsSection(
                    activePodcastIDs: activePodcastIDs,
                    subscribingFeedURLString: subscribingFeedURLString,
                    onSubscribe: onSubscribeSample
                )

                if let clipboardErrorMessage {
                    Label(clipboardErrorMessage, systemImage: "doc.on.clipboard")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                }

                if let subscriptionErrorMessage {
                    Label(subscriptionErrorMessage, systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollIndicators(.hidden)
    }

    private var isSubscribing: Bool {
        subscribingFeedURLString != nil
    }
}
