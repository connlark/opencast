import SwiftUI

/// Asks whether playing a playlist should replace Up Next or join behind it.
/// Attach it to the control that triggers the play so Liquid Glass sources
/// the dialog from that control.
struct PlaylistReplaceConfirmationModifier: ViewModifier {
    @Binding var isPresented: Bool
    let queuedCount: Int
    let onChoose: (PlaylistPlayMode) -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog("Replace Up Next?", isPresented: $isPresented, titleVisibility: .visible) {
                Button("Replace Up Next", action: replace)
                Button("Add After Up Next", action: addAfter)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(message)
            }
    }

    // Grammar agreement resolves only on the attributed localization path.
    private var message: String {
        String(AttributedString(localized: "Up Next has ^[\(queuedCount) episode](inflect: true).").characters)
    }

    private func replace() {
        onChoose(.replace)
    }

    private func addAfter() {
        onChoose(.addAfter)
    }
}

extension View {
    func playlistReplaceConfirmation(
        isPresented: Binding<Bool>,
        queuedCount: Int,
        onChoose: @escaping (PlaylistPlayMode) -> Void
    ) -> some View {
        modifier(PlaylistReplaceConfirmationModifier(isPresented: isPresented, queuedCount: queuedCount, onChoose: onChoose))
    }
}
