import OpenCastCore
import SwiftUI

struct OnboardingPodcastSetupPage: View {
    @Bindable var searchStore: PodcastSearchStore
    @Binding var selectedMode: AddPodcastMode
    @Binding var feedURLString: String

    let focusedField: FocusState<OnboardingFocusedField?>.Binding
    let subscriptions: [SubscriptionRecord]
    let activePodcastIDs: Set<String>
    let isSubscribing: Bool
    let subscribingResultID: String?
    let subscriptionErrorMessage: String?
    let clipboardErrorMessage: String?
    let canSubscribeToRawFeed: Bool
    let onPaste: () -> Void
    let onSubscribeRawFeed: () -> Void
    let onSubscribeSearchResult: (DirectoryPodcastResult) -> Void
    let onSubscribeSample: (DirectoryPodcastResult) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Find Podcasts")
                        .font(.largeTitle)
                        .bold()

                    Text(instructionText)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

                GlassEffectContainer(spacing: 18) {
                    VStack(alignment: .leading, spacing: 18) {
                        AddPodcastModePicker(selectedMode: $selectedMode)
                            .padding(4)
                            .glassEffect(.regular, in: .rect(cornerRadius: 22))

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
                                isSubscribing: isSubscribing,
                                subscribingResultID: subscribingResultID,
                                onSubscribe: onSubscribeSearchResult
                            )
                        }

                        if subscriptions.isEmpty {
                            OnboardingSamplePodcastsSection(
                                activePodcastIDs: activePodcastIDs,
                                isSubscribing: isSubscribing,
                                subscribingResultID: subscribingResultID,
                                onSubscribe: onSubscribeSample
                            )
                        } else {
                            OnboardingSubscribedPodcastsSection(subscriptions: subscriptions)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

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
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollIndicators(.hidden)
        .scrollContentBackground(.visible)
    }

    private var instructionText: String {
        subscriptions.isEmpty
            ? "Search by name, paste an RSS feed URL, or start with a sample show."
            : "Search by name, paste an RSS feed URL, or keep building from your imported library."
    }
}
