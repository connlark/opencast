import SwiftData
import SwiftUI

struct LibrarySubscriptionRowView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @State private var isConfirmingUnsubscribe = false

    let subscription: SubscriptionRecord
    let usesNavigationLinks: Bool
    let onOpenPodcast: (String) -> Void

    static func accessibilityIdentifier(for feedURL: String) -> String {
        "subscription-row-\(feedURL)"
    }

    var body: some View {
        Group {
            if usesNavigationLinks {
                NavigationLink(value: AppRoute.podcastDetail(feedURL: subscription.feedURL)) {
                    subscriptionRow()
                }
            } else {
                Button(action: openPodcast) {
                    subscriptionRow()
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityIdentifier(Self.accessibilityIdentifier(for: subscription.feedURL))
        .swipeActions(edge: .trailing) {
            Button("Remove", systemImage: "trash", action: confirmUnsubscribe)
                .tint(.red)
        }
        .confirmationDialog(
            "Remove \(subscription.title)?",
            isPresented: $isConfirmingUnsubscribe,
            titleVisibility: .visible
        ) {
            Button("Remove Podcast", role: .destructive, action: unsubscribe)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Cached episodes, progress, refresh logs, and local downloads for this podcast will be removed.")
        }
    }

    private func subscriptionRow() -> some View {
        SubscriptionRowView(
            subscription: subscription,
            podcastCache: appModel.library.podcastCache(for: subscription.feedURL),
            latestRefreshLog: appModel.library.latestRefreshLogByFeedURL[subscription.feedURL],
            isRefreshing: appModel.library.isRefreshing(feedURL: subscription.feedURL)
        )
    }

    private func openPodcast() {
        onOpenPodcast(subscription.feedURL)
    }

    private func confirmUnsubscribe() {
        isConfirmingUnsubscribe = true
    }

    private func unsubscribe() {
        appModel.unsubscribe(feedURL: subscription.feedURL, modelContext: modelContext)
    }
}
