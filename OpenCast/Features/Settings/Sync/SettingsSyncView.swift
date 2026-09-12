import SwiftUI

struct SettingsSyncView: View {
    @Environment(OpenCastAppModel.self) private var appModel

    var body: some View {
        Form {
            SettingsSyncSection(accountStatus: appModel.syncStatus.accountStatus)
            SettingsSyncDetailsSection()
        }
        .settingsSubscreen(title: "iCloud Sync")
    }
}
