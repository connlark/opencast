import SwiftUI

struct SettingsImportExportView: View {
    var body: some View {
        Form {
            OPMLSettingsSection()
        }
        .settingsSubscreen(title: "Import & Export")
    }
}
