import SwiftData
import SwiftUI

struct LibraryView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.modelContext) private var modelContext
    @State private var sampleSubscriptionErrorMessage: String?
    @State private var isSubscribingSample = false

    let onAdd: () -> Void

    var body: some View {
        content
            .animation(reduceMotion ? nil : .default, value: appModel.library.state)
            .animation(
                reduceMotion ? nil : .default,
                value: appModel.library.subscriptions.map(\.feedURL)
            )
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

    @ViewBuilder
    private var content: some View {
        switch appModel.library.state {
        case .loading where appModel.library.subscriptions.isEmpty:
            List {
                ProgressView()
            }
        case .failed(let message) where appModel.library.subscriptions.isEmpty:
            List {
                ContentUnavailableView(
                    "Library Unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
            }
        default:
            if appModel.library.subscriptions.isEmpty {
                List {
                    LibraryEmptyStateView(
                        syncActivity: appModel.syncStatus.libraryActivity,
                        isSubscribingSample: isSubscribingSample,
                        sampleSubscriptionErrorMessage: sampleSubscriptionErrorMessage,
                        onAdd: onAdd,
                        onSubscribeSample: subscribeToSample
                    )
                }
            } else if horizontalSizeClass == .regular {
                subscriptionGrid
            } else {
                List {
                    subscriptionRows
                }
            }
        }
    }

    private var subscriptionGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 160, maximum: 240), spacing: 16)],
                spacing: 24
            ) {
                ForEach(appModel.library.subscriptions) { subscription in
                    LibrarySubscriptionTileView(subscription: subscription)
                }
            }
            .padding(.vertical, 8)
        }
        .contentMargins(.horizontal, 24, for: .scrollContent)
        .contentMargins(.bottom, 72, for: .scrollContent)
    }

    private var subscriptionRows: some View {
        ForEach(appModel.library.subscriptions) { subscription in
            LibrarySubscriptionRowView(subscription: subscription)
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
