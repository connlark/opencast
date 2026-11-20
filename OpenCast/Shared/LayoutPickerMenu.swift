import SwiftUI

/// Checkmarks follow the stored choice, so Automatic stays checked whichever layout it
/// resolves to; the icon follows the layout on screen.
struct LayoutPickerMenu<AdditionalItems: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Binding var layout: LibraryLayoutPreference
    let resolvedLayout: LibraryLayout
    let title: String
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
