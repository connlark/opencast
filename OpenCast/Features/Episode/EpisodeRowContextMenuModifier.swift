import SwiftUI

struct EpisodeRowContextMenuModifier: ViewModifier {
    let episode: EpisodeListItemSnapshot
    let onViewDetails: (EpisodeListItemSnapshot) -> Void

    func body(content: Content) -> some View {
        content.contextMenu {
            Button("View Episode Details", systemImage: "info.circle", action: viewDetails)
        } preview: {
            EpisodeContextPreviewView(episode: episode)
        }
    }

    private func viewDetails() {
        onViewDetails(episode)
    }
}
