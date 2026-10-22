import SwiftUI

struct DownloadsEmptyStateView: View {
    var body: some View {
        ContentUnavailableView {
            Label("No Downloads", systemImage: "arrow.down.circle")
        } description: {
            Text("Download an episode from its detail screen or context menu to listen offline.")
        } actions: {
            // Shows can download new episodes on their own, so the settings
            // are reachable before anything is downloaded.
            NavigationLink("Download Settings", value: AppRoute.downloadSettings)
                .buttonStyle(.glass)
        }
    }
}
