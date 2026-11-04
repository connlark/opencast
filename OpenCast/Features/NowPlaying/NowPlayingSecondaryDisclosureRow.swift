import SwiftUI

/// The secondary pane collapsed to one row on a tall foldable display: it
/// names the remembered mode, and expanding it shows the same pane inline.
struct NowPlayingSecondaryDisclosureRow: View {
    static let accessibilityIdentifier = "Now Playing Secondary Pane Row"

    let selection: NowPlayingSecondaryPane
    let isExpanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Label(selection.title, systemImage: selection.systemImage)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, 8)
            .contentShape(.rect)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .accessibilityValue(isExpanded ? Text("Expanded") : Text("Collapsed"))
        .accessibilityHint(isExpanded ? Text("Hides the pane") : Text("Shows the pane"))
        .accessibilityIdentifier(Self.accessibilityIdentifier)
    }
}
