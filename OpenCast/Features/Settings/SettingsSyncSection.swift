import SwiftUI

struct SettingsSyncSection: View {
    let accountStatus: SyncAccountStatus

    var body: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text(statusTitle)
                    Text(statusSubtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if let detail = accountStatus.detail {
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: statusSystemImage)
                    .font(.title3)
                    .foregroundStyle(statusForegroundStyle)
            }
        } header: {
            Text("iCloud Sync")
        } footer: {
            Text("Your podcast list and listening progress stay private in your iCloud account when sync is available.")
        }
    }

    private var statusTitle: String {
        switch accountStatus {
        case .available:
            "iCloud Sync On"
        case .checking, .notChecked:
            "Checking iCloud"
        case .noAccount:
            "iCloud Sync Off"
        case .restricted, .couldNotDetermine, .temporarilyUnavailable:
            "iCloud Sync Unavailable"
        }
    }

    private var statusSubtitle: String {
        switch accountStatus {
        case .available:
            "Subscriptions and listening progress are syncing."
        case .checking, .notChecked:
            "Subscriptions and listening progress will sync when iCloud is available."
        case .noAccount:
            "opencast will keep working locally on this device."
        case .restricted, .couldNotDetermine, .temporarilyUnavailable:
            "Subscriptions, playback, downloads, and settings remain available on this device."
        }
    }

    private var statusSystemImage: String {
        switch accountStatus {
        case .available:
            "checkmark.circle.fill"
        case .checking, .notChecked:
            "icloud"
        case .noAccount:
            "icloud.slash"
        case .restricted, .couldNotDetermine, .temporarilyUnavailable:
            "exclamationmark.icloud"
        }
    }

    private var statusForegroundStyle: Color {
        switch accountStatus {
        case .available:
            .green
        case .checking, .notChecked:
            .secondary
        case .noAccount:
            .secondary
        case .restricted, .couldNotDetermine, .temporarilyUnavailable:
            .orange
        }
    }
}
