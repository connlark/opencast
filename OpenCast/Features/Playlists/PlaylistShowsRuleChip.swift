import SwiftUI

/// The Shows chip. Unlike the other chips it opens a sheet, not a menu: an
/// iOS 27 menu rebuilds its open content whenever a value it reads changes,
/// so each pick in a long checklist snapped the list back to the top, and a
/// rebuild under a scrolling finger could land as a pick. A sheet's list
/// keeps its place while the rule changes under it.
///
/// The sheet is presented here rather than through `SheetDestination`
/// because a destination carries only identifiers, and the chips know only
/// the rule: they report each change through `onChange` and the caller
/// saves it. Presenting from the chip keeps every pick on that one save
/// path, and the sheet reads the saved rule each time the chip re-renders.
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
