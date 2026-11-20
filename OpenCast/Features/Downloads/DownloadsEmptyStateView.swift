import SwiftUI

struct DownloadsEmptyStateView: View {
    let onOpenDownloadSettings: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("No Downloads", systemImage: "arrow.down.circle")
        } description: {
            Text("Download an episode from its detail screen or context menu to listen offline.")
        } actions: {
            // A Button, not a NavigationLink: in the List row that hosts this view a link
            // takes the whole row's taps.
            Button("Download Settings", action: onOpenDownloadSettings)
                .buttonStyle(.glass)
        }
    }
}
