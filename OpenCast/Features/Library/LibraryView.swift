import SwiftData
import SwiftUI

struct LibraryView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @State private var sampleSubscriptionErrorMessage: String?
    @State private var isSubscribingSample = false

    let usesNavigationLinks: Bool
    let onAdd: () -> Void
    let onOpenPodcast: (String) -> Void

    var body: some View {
        List {
            switch appModel.library.state {
            case .loading where appModel.library.subscriptions.isEmpty:
                ProgressView()
            case .failed(let message) where appModel.library.subscriptions.isEmpty:
                ContentUnavailableView("Library Unavailable", systemImage: "exclamationmark.triangle", description: Text(message))
            default:
                if appModel.library.subscriptions.isEmpty {
                    LibraryEmptyStateView(
                        syncActivity: appModel.syncStatus.libraryActivity,
                        isSubscribingSample: isSubscribingSample,
                        sampleSubscriptionErrorMessage: sampleSubscriptionErrorMessage,
                        onAdd: onAdd,
                        onSubscribeSample: subscribeToSample
                    )
                } else {
                    ForEach(appModel.library.subscriptions) { subscription in
                        LibrarySubscriptionRowView(
                            subscription: subscription,
                            usesNavigationLinks: usesNavigationLinks,
                            onOpenPodcast: onOpenPodcast
                        )
                    }
                }
            }
        }
        .navigationTitle("Library")
        .refreshable {
            await appModel.library.refreshAll(modelContext: modelContext)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add", systemImage: "plus", action: onAdd)
            }
        }
    }

    private func subscribeToSample() {
        guard !isSubscribingSample else {
            return
        }

        Task {
            await performSampleSubscription()
        }
    }

    private func performSampleSubscription() async {
        sampleSubscriptionErrorMessage = nil
        isSubscribingSample = true
        defer {
            isSubscribingSample = false
        }

        do {
            try await appModel.library.subscribe(
                to: OpenCastConstants.thisAmericanLifeFeedURL,
                modelContext: modelContext
            )
        } catch is CancellationError {
        } catch {
            sampleSubscriptionErrorMessage = error.localizedDescription
        }
    }
}
