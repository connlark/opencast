import SwiftUI

struct SettingsRouteDestinationView: View {
    let route: SettingsRoute

    var body: some View {
        switch route {
        case .playback:
            SettingsPlaybackView()
        case .inbox:
            SettingsInboxView()
        case .appIcon:
            SettingsAppIconView()
        case .notifications:
            SettingsNotificationsView()
        case .transcription:
            SettingsTranscriptionView()
        case .adSkipping:
            SettingsAdSkippingView()
        case .credits:
            SettingsCreditsView()
        case .sync:
            SettingsSyncView()
        case .storage:
            SettingsStorageView()
        case .importExport:
            SettingsImportExportView()
        case .help:
            HelpHubView()
        case .helpTopic(let id):
            HelpTopicView(topicID: id)
        case .about:
            SettingsAboutView()
        case .diagnostics:
            DiagnosticsView()
        case .refreshLogs:
            RefreshLogListView()
        case .deleteData:
            SettingsDeleteDataView()
        }
    }
}
