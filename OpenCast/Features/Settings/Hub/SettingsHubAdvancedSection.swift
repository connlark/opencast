import SwiftUI

struct SettingsHubAdvancedSection: View {
    var body: some View {
        Section("Advanced") {
            SettingsNavigationRow(title: "Diagnostics", systemImage: "stethoscope", route: .diagnostics)
            SettingsNavigationRow(title: "Delete Data", systemImage: "trash", route: .deleteData)
        }
    }
}
