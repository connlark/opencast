import SwiftUI

/// "Share Episode" for the episode menus, or a nested "Share" menu that adds
/// "Share from 12:34" when the episode has a playhead ("Share from Current
/// Time" while it plays). A child view so the state reads and the token
/// encode run when the menu is realised, not in the host's body (menu and
/// context-menu builders run inline in their host).
struct EpisodeShareMenu: View {
    @Environment(OpenCastAppModel.self) private var appModel

    let episode: EpisodeListItemSnapshot

    var body: some View {
        if let context = EpisodeShareContext.make(episode: episode, appModel: appModel) {
            // Supplying the preview also keeps the share sheet from fetching
            // the link's metadata from the worker before a target is chosen.
            let preview = SharePreview(context.title, image: previewImage(for: context))
            if let start = context.start {
                Menu("Share", systemImage: "square.and.arrow.up") {
                    // No message: text plus a URL makes Messages send a text
                    // bubble instead of the link card.
                    ShareLink(item: context.url, subject: Text(context.title), preview: preview) {
                        Label("Share Episode", systemImage: "square.and.arrow.up")
                    }
                    switch start {
                    case .fixed(let startURL, let label):
                        ShareLink(item: startURL, subject: Text(context.title), preview: preview) {
                            Label("Share from \(label)", systemImage: "clock")
                        }
                    case .currentTime:
                        ShareLink(item: currentTimeLink(for: context), subject: Text(context.title), preview: preview) {
                            Label("Share from Current Time", systemImage: "clock")
                        }
                    }
                }
            } else {
                ShareLink(item: context.url, subject: Text(context.title), preview: preview) {
                    Label("Share Episode", systemImage: "square.and.arrow.up")
                }
            }
        }
    }

    private func currentTimeLink(for context: EpisodeShareContext) -> EpisodeCurrentTimeShareLink {
        let playhead = appModel.playback.playheadMirror
        let episodeID = episode.episodeID
        return EpisodeCurrentTimeShareLink {
            let reading = playhead.read()
            // Playback may have moved to another episode by the time the
            // link is shared; that position means nothing for this one.
            guard reading.episodeID?.rawValue == episodeID else {
                return context.url
            }
            return context.url(startingAt: reading.position)
        }
    }

    private func previewImage(for context: EpisodeShareContext) -> Image {
        if let artworkURL = context.artworkURL,
           let artwork = ArtworkLoader.shared.bestCachedImage(
               for: ArtworkRequest(url: artworkURL, targetPixelSize: CGSize(width: 512, height: 512))
           ) {
            return Image(uiImage: artwork)
        }
        return Image(appModel.appIcon.selection.previewImage)
    }
}

#Preview {
    NavigationStack {
        Text("Episode")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu("Episode Actions", systemImage: "ellipsis.circle") {
                        Section {
                            EpisodeShareMenu(episode: .previewSample)
                        }
                    }
                }
            }
    }
    .environment(OpenCastAppModel())
}
