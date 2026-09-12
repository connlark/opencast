import SwiftUI

struct SettingsSubscreenModifier: ViewModifier {
    let title: String

    func body(content: Content) -> some View {
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .contentMargins(.bottom, SettingsView.compactMiniPlayerScrollMargin, for: .scrollContent)
    }
}

extension View {
    func settingsSubscreen(title: String) -> some View {
        modifier(SettingsSubscreenModifier(title: title))
    }
}
