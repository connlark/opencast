import SwiftUI

struct DownloadsEmptyStateView: View {
    var body: some View {
        ContentUnavailableView(
            "No Downloads",
            systemImage: "arrow.down.circle",
            description: Text("Download an episode from its detail screen or context menu to listen offline.")
        )
    }
}
