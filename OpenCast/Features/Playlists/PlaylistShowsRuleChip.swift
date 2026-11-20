import SwiftUI

/// A sheet, not a menu: an iOS 27 menu rebuilds its open content when a value it reads changes,
/// snapping a long checklist to the top. Presented here, not through `SheetDestination`, which
/// carries only identifiers, so every pick stays on the chips' one `onChange` save path.
struct PlaylistShowsRuleChip: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @State private var isPickerPresented = false

    let rule: PlaylistRule
    let onChange: (PlaylistRule) -> Void

    var body: some View {
        let title = rule.showsTitle(subscribedPodcastIDs: appModel.library.activePodcastIDs)
        Button(action: showPicker) {
            PlaylistRuleChipLabel(title: title, systemImage: "books.vertical")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Shows, \(title)")
        .accessibilityInputLabels(["Shows", title])
        .accessibilityIdentifier("Smart Rule Shows")
        .sheet(isPresented: $isPickerPresented) {
            PlaylistShowsPickerSheet(rule: rule, onChange: onChange)
                .environment(appModel)
                // The chips set a subheadline font that the sheet would inherit.
                .font(.body)
        }
    }

    private func showPicker() {
        isPickerPresented = true
    }
}
