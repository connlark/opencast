import SwiftUI

struct SyncLibraryActivityView: View {
    let activity: SyncLibraryActivity

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(activity.title)
                Text(activity.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            if activity.showsProgress {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: activity.systemImage)
                    .foregroundStyle(.orange)
            }
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("Sync Library Activity")
    }
}
