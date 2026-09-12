import SwiftUI

struct SettingsHubDataSection: View {
    @Environment(OpenCastAppModel.self) private var appModel

    var body: some View {
        Section("Data") {
            SettingsNavigationRow(title: "iCloud Sync", systemImage: "icloud", route: .sync, value: syncValue)
            SettingsNavigationRow(title: "Storage", systemImage: "internaldrive", route: .storage, value: storageValue)
            SettingsNavigationRow(
                title: "Import & Export",
                systemImage: "square.and.arrow.up.on.square",
                route: .importExport
            )
        }
    }

    private var syncValue: String {
        switch appModel.syncStatus.accountStatus {
        case .available:
            "On"
        case .noAccount:
            "Off"
        case .notChecked, .checking:
            "Checking…"
        case .restricted, .couldNotDetermine, .temporarilyUnavailable:
            "Unavailable"
        }
    }

    private var storageValue: String {
        let byteCount = appModel.cacheController.feedCacheSummary.byteCount
            + appModel.cacheController.artworkCacheSummary.byteCount
            + appModel.downloads.completedDownloadByteCount
        return byteCount > 0 ? byteCount.formatted(.byteCount(style: .file)) : "None"
    }
}
