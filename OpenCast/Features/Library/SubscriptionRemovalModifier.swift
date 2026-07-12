import SwiftData
import SwiftUI

struct SubscriptionRemovalModifier: ViewModifier {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    @Binding var isConfirmingRemoval: Bool
    let subscription: SubscriptionRecord
    let supportsSwipeAction: Bool
    let supportsContextMenu: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        switch (supportsSwipeAction, supportsContextMenu) {
        case (true, true):
            content
                .contextMenu {
                    contextMenuRemoveButton
                }
                .swipeActions(edge: .trailing) {
                    swipeRemoveButton
                }
                .confirmationDialog(
                    "Remove \(subscription.title)?",
                    isPresented: $isConfirmingRemoval,
                    titleVisibility: .visible
                ) {
                    Button("Remove Podcast", role: .destructive, action: removePodcast)
                    Button("Cancel", role: .cancel) {}
                } message: {
                    removalMessage
                }
        case (true, false):
            content
                .swipeActions(edge: .trailing) {
                    swipeRemoveButton
                }
                .confirmationDialog(
                    "Remove \(subscription.title)?",
                    isPresented: $isConfirmingRemoval,
                    titleVisibility: .visible
                ) {
                    Button("Remove Podcast", role: .destructive, action: removePodcast)
                    Button("Cancel", role: .cancel) {}
                } message: {
                    removalMessage
                }
        case (false, true):
            content
                .contextMenu {
                    contextMenuRemoveButton
                }
                .confirmationDialog(
                    "Remove \(subscription.title)?",
                    isPresented: $isConfirmingRemoval,
                    titleVisibility: .visible
                ) {
                    Button("Remove Podcast", role: .destructive, action: removePodcast)
                    Button("Cancel", role: .cancel) {}
                } message: {
                    removalMessage
                }
        case (false, false):
            content
                .confirmationDialog(
                    "Remove \(subscription.title)?",
                    isPresented: $isConfirmingRemoval,
                    titleVisibility: .visible
                ) {
                    Button("Remove Podcast", role: .destructive, action: removePodcast)
                    Button("Cancel", role: .cancel) {}
                } message: {
                    removalMessage
                }
        }
    }

    private var swipeRemoveButton: some View {
        Button("Remove", systemImage: "trash", action: confirmRemoval)
            .tint(.red)
    }

    private var contextMenuRemoveButton: some View {
        Button("Remove Podcast", systemImage: "trash", role: .destructive, action: confirmRemoval)
    }

    private var removalMessage: Text {
        Text("Cached episodes, progress, refresh logs, and local downloads for this podcast will be removed.")
    }

    private func confirmRemoval() {
        isConfirmingRemoval = true
    }

    private func removePodcast() {
        Task {
            await appModel.unsubscribe(feedURL: subscription.feedURL, modelContext: modelContext)
        }
    }
}
