import SwiftUI

/// The trailing swipe on a manual playlist's rows. It replaces the delete
/// swipe `onDelete` would synthesize, so edit mode keeps its delete control
/// while the swipe reads "Remove": the episode leaves the playlist, not the
/// library.
struct PlaylistRowActionsModifier: ViewModifier {
    let onRemove: () -> Void

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .trailing) {
                Button("Remove", systemImage: "minus.circle", role: .destructive, action: onRemove)
            }
    }
}
