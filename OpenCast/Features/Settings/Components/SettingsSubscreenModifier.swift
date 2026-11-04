import SwiftUI

struct SettingsSubscreenModifier: ViewModifier {
    let title: String
    /// Nil for the List and Form subscreens: the shell's row gap.
    let rowSpacing: Double?

    func body(content: Content) -> some View {
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .modifier(TabAccessoryBottomClearance(rowSpacing: rowSpacing))
    }
}

extension View {
    /// `rowSpacing` is a scroll view subscreen's own spacing between its
    /// sections; List and Form subscreens leave it nil.
    func settingsSubscreen(title: String, rowSpacing: Double? = nil) -> some View {
        modifier(SettingsSubscreenModifier(title: title, rowSpacing: rowSpacing))
    }
}
