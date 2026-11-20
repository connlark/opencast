import SwiftUI

/// Replaces the swipe `onDelete` would synthesize, so edit mode keeps its delete control while
/// the swipe reads "Remove".
struct PlaylistRowActionsModifier: ViewModifier {
    let onRemove: () -> Void

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .trailing) {
                Button("Remove", systemImage: "minus.circle", role: .destructive, action: onRemove)
            }
    }
}
