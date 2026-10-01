import SwiftUI

/// The Automatic / List / Grid picker behind a toolbar icon, shared by the
/// Library and the Group by Podcast Inbox. Checkmarks follow the stored
/// choice (Automatic stays checked while it resolves to either layout); the
/// icon follows the layout on screen. Persisting and haptics stay with the
/// caller's binding, so each view keeps its own preference.
struct LayoutPickerMenu<AdditionalItems: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Binding var layout: LibraryLayoutPreference
    let resolvedLayout: LibraryLayout
    let title: String
    /// Further menu items below the layout picker, such as the Library's Sort By.
    let additionalItems: AdditionalItems

    init(
        layout: Binding<LibraryLayoutPreference>,
        resolvedLayout: LibraryLayout,
        title: String = "Layout",
        @ViewBuilder additionalItems: () -> AdditionalItems
    ) {
        _layout = layout
        self.resolvedLayout = resolvedLayout
        self.title = title
        self.additionalItems = additionalItems()
    }

    var body: some View {
        Menu {
            Picker("Layout", selection: $layout) {
                ForEach(LibraryLayoutPreference.allCases) { layout in
                    Label(layout.title, systemImage: layout.systemImage)
                        .tag(layout)
                }
            }
            .pickerStyle(.inline)

            additionalItems
        } label: {
            Label(title, systemImage: resolvedLayout.systemImage)
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
        }
        .accessibilityValue(resolvedLayout.title)
    }
}

extension LayoutPickerMenu where AdditionalItems == EmptyView {
    init(layout: Binding<LibraryLayoutPreference>, resolvedLayout: LibraryLayout, title: String = "Layout") {
        self.init(layout: layout, resolvedLayout: resolvedLayout, title: title) {
            EmptyView()
        }
    }
}
