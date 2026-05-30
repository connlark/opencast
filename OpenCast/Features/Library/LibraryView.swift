import SwiftData
import SwiftUI

struct LibraryView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

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
                    ContentUnavailableView("No Subscriptions", systemImage: "books.vertical")
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
}
