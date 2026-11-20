import SwiftUI

struct PlaylistPriorityRuleChip: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @State private var isPickerPresented = false

    let rule: PlaylistRule
    let onChange: (PlaylistRule) -> Void

    var body: some View {
        let title = rule.priorityTitle(subscribedPodcastIDs: appModel.library.activePodcastIDs)
        Button(action: showPicker) {
            PlaylistRuleChipLabel(title: title, systemImage: "arrow.up.to.line")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Priority, \(title)")
        .accessibilityInputLabels(["Priority", title])
        .accessibilityIdentifier("Smart Rule Priority")
        .sheet(isPresented: $isPickerPresented) {
            PlaylistPriorityPickerSheet(rule: rule, onChange: onChange)
                .environment(appModel)
                // The chips set a subheadline font that the sheet would inherit.
                .font(.body)
        }
    }

    private func showPicker() {
        isPickerPresented = true
    }
}
