import SwiftData
import SwiftUI

/// The Library's layout and sort menu. Checkmarks follow the stored choice
/// (Automatic stays checked while it resolves to either layout); the toolbar
/// icon follows the layout on screen.
struct LibraryViewOptionsMenu: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.modelContext) private var modelContext
    @State private var selectionFeedbackTrigger = 0

    let resolvedLayout: LibraryLayout

    var body: some View {
        Menu {
            Picker("Layout", selection: layoutBinding) {
                ForEach(LibraryLayoutPreference.allCases) { layout in
                    Label(layout.title, systemImage: layout.systemImage)
                        .tag(layout)
                }
            }
            .pickerStyle(.inline)

            Picker(selection: sortOrderBinding) {
                ForEach(LibrarySortOrder.allCases) { sortOrder in
                    Text(sortOrder.title)
                        .tag(sortOrder)
                }
            } label: {
                Label("Sort By", systemImage: "arrow.up.arrow.down")
            }
            .pickerStyle(.menu)
        } label: {
            Label("View Options", systemImage: resolvedLayout.systemImage)
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
        }
        .accessibilityValue(resolvedLayout.title)
        .accessibilityIdentifier("Library View Options")
        // Keyed to user picks, not the stored values: loading a stored
        // layout at launch or resizing an Automatic layout must not buzz.
        .sensoryFeedback(.selection, trigger: selectionFeedbackTrigger)
    }

    private var layoutBinding: Binding<LibraryLayoutPreference> {
        Binding {
            appModel.libraryDisplaySettings.layout
        } set: { layout in
            guard layout != appModel.libraryDisplaySettings.layout,
                  appModel.libraryDisplaySettings.setLayout(layout, modelContext: modelContext)
            else {
                return
            }
            selectionFeedbackTrigger += 1
        }
    }

    private var sortOrderBinding: Binding<LibrarySortOrder> {
        Binding {
            appModel.libraryDisplaySettings.sortOrder
        } set: { sortOrder in
            guard sortOrder != appModel.libraryDisplaySettings.sortOrder,
                  appModel.libraryDisplaySettings.setSortOrder(sortOrder, modelContext: modelContext)
            else {
                return
            }
            selectionFeedbackTrigger += 1
        }
    }
}
