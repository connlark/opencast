import SwiftData
import SwiftUI

/// The Group by Podcast Inbox's layout menu: the shared `LayoutPickerMenu`
/// bound to the Inbox's own layout preference, shown left of the filter
/// menu while grouping is on.
struct InboxGroupedLayoutMenu: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @State private var selectionFeedbackTrigger = 0

    let resolvedLayout: LibraryLayout

    var body: some View {
        LayoutPickerMenu(layout: layoutBinding, resolvedLayout: resolvedLayout)
            .accessibilityIdentifier("Inbox Layout Options")
            // Keyed to user picks, not the stored value: loading a stored
            // layout at launch or resizing an Automatic layout must not buzz.
            .sensoryFeedback(.selection, trigger: selectionFeedbackTrigger)
    }

    private var layoutBinding: Binding<LibraryLayoutPreference> {
        Binding {
            appModel.inboxEpisodeListSettings.groupedLayout
        } set: { layout in
            guard layout != appModel.inboxEpisodeListSettings.groupedLayout,
                  appModel.inboxEpisodeListSettings.setGroupedLayout(layout, modelContext: modelContext)
            else {
                return
            }
            selectionFeedbackTrigger += 1
        }
    }
}
