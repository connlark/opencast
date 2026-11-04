import SwiftUI

/// The segmented secondary pane: Up Next, Transcript, Chapters and Show
/// Notes, each the view its sheet or page already uses, embedded so its
/// actions keep the player and the pane on screen. `content` nil draws a
/// placeholder: an open sheet is already showing the selected destination.
struct NowPlayingSecondaryPaneView: View {
    @Environment(OpenCastAppModel.self) private var appModel

    @Binding var selection: NowPlayingSecondaryPane
    let content: NowPlayingSecondaryPane?
    /// The window's safe rectangle and any band or occlusion, already
    /// converted into this pane's coordinates.
    var contentInsets = EdgeInsets()

    /// The picker's gap below the pane's top inset.
    static let pickerTopPadding: CGFloat = 12

    var body: some View {
        VStack(spacing: 8) {
            NowPlayingSecondaryPanePicker(selection: $selection)
                .padding(.horizontal, 16)
                .padding(.top, Self.pickerTopPadding)

            paneContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(contentInsets)
    }

    @ViewBuilder
    private var paneContent: some View {
        switch content {
        case .upNext:
            UpNextQueueView(host: .pane)
        case .transcript:
            NavigationStack {
                if let episodeID = appModel.playback.currentEpisode?.id.rawValue {
                    // A new episode gets a new transcript view, never the
                    // previous episode's loaded document.
                    EpisodeTranscriptView(episodeID: episodeID)
                        .id(episodeID)
                } else {
                    ContentUnavailableView("Nothing Playing", systemImage: "play.circle")
                }
            }
        case .chapters:
            NowPlayingChaptersView(host: .pane)
        case .showNotes:
            if let episode = appModel.playback.currentEpisode {
                NowPlayingShowNotesPaneView(episode: episode)
            } else {
                ContentUnavailableView("Nothing Playing", systemImage: "play.circle")
            }
        case nil:
            ContentUnavailableView(
                selection.title,
                systemImage: selection.systemImage,
                description: Text("Open in a sheet.")
            )
        }
    }
}
