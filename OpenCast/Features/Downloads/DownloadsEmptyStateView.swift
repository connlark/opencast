import SwiftUI

struct DownloadsEmptyStateView: View {
    let onOpenDownloadSettings: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("No Downloads", systemImage: "arrow.down.circle")
        } description: {
            Text("Download an episode from its detail screen or context menu to listen offline.")
        } actions: {
            // Shows can download new episodes on their own, so the settings
            // are reachable before anything is downloaded. Downloads shows
            // this as a List row, and a NavigationLink there makes the whole
            // row the link; a button takes only its own taps.
            Button("Download Settings", action: onOpenDownloadSettings)
                .buttonStyle(.glass)
        }
    }
}
