import SwiftData
import SwiftUI

struct SubscriptionRemovalModifier: ViewModifier {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    @Binding var isConfirmingRemoval: Bool
    let subscription: SubscriptionRecord
    let supportsSwipeAction: Bool
    let supportsContextMenu: Bool

    @State private var removalErrorMessage: String?

    func body(content: Content) -> some View {
        decoratedContent(content)
            .alert(
                "Remove Podcast",
                // Alert API exception: no item: overload for a
                // non-Identifiable optional.
                isPresented: Binding(
                    get: { removalErrorMessage != nil },
                    set: { isPresented in
                        if !isPresented {
                            removalErrorMessage = nil
                        }
                    }
                )
            ) {
            } message: {
                Text(removalErrorMessage ?? "")
            }
    }

    @ViewBuilder
    private func decoratedContent(_ content: Content) -> some View {
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
                    removalDialogButtons
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
                    removalDialogButtons
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
                    removalDialogButtons
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
                    removalDialogButtons
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

    @ViewBuilder
    private var removalDialogButtons: some View {
        Button("Remove Podcast", role: .destructive, action: removePodcast)
        Button("Remove & Clear History", role: .destructive, action: removePodcastAndClearHistory)
        Button("Cancel", role: .cancel) {}
    }

    private var removalMessage: Text {
        Text("Downloads and cached episodes for this podcast will be removed. Listening history is kept unless you clear it.")
    }

    private func confirmRemoval() {
        isConfirmingRemoval = true
    }

    private func removePodcast() {
        removePodcast(clearListeningHistory: false)
    }

    private func removePodcastAndClearHistory() {
        removePodcast(clearListeningHistory: true)
    }

    private func removePodcast(clearListeningHistory: Bool) {
        Task {
            let outcome = await appModel.unsubscribe(
                feedURL: subscription.feedURL,
                modelContext: modelContext,
                clearListeningHistory: clearListeningHistory
            )
            removalErrorMessage = outcome.userFacingMessage
        }
    }
}
