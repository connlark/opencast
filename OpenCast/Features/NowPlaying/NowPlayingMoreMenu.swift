import SwiftUI

struct NowPlayingMoreMenu: View {
    /// The cached snapshot of the current episode, for sharing; nil when the
    /// episode is neither cached nor downloaded.
    let episode: EpisodeListItemSnapshot?
    let hasTranscript: Bool
    let canShowDescription: Bool
    let canShowShow: Bool
    /// The name of the playlist playback came from; nil when there is none.
    let playlistSourceName: String?
    /// Whether Private Notes appears; follows the Playback setting that shows
    /// the note circle, so a listener who hasn't opted in doesn't see it here
    /// either. Adding a note is the circle's job, never the menu's.
    let showsPrivateNotes: Bool
    let onTranscriptAction: () -> Void
    let onShowNotes: () -> Void
    let onShowDescription: () -> Void
    let onShowShow: () -> Void
    let onShowPlaylist: () -> Void
    let onAddToPlaylist: () -> Void
    let onStopPlayback: () -> Void

    var body: some View {
        Menu {
            if let episode {
                Section {
                    EpisodeShareMenu(episode: episode)
                }
            }
            Button(
                hasTranscript ? "Show Transcript" : "Generate Transcript",
                systemImage: "text.quote",
                action: onTranscriptAction
            )
            if showsPrivateNotes {
                Button("Private Notes", systemImage: "note.text", action: onShowNotes)
                    .accessibilityIdentifier("Menu Private Notes")
            }
            Button("Show Description", systemImage: "info.circle", action: onShowDescription)
                .disabled(!canShowDescription)
            Button("Show Show", systemImage: "rectangle.stack", action: onShowShow)
                .disabled(!canShowShow)
            if let playlistSourceName {
                Button(
                    PlaylistPlaybackSourceText.showPlaylistMenuTitle(name: playlistSourceName),
                    systemImage: "music.note.list",
                    action: onShowPlaylist
                )
            }
            if episode != nil {
                Button("Add to Playlist…", systemImage: "music.note.list", action: onAddToPlaylist)
            }
            Divider()
            Button("Stop Playback", systemImage: "stop.circle", action: onStopPlayback)
        } label: {
            Label("More Actions", systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
                .font(.title3)
                .frame(width: 44, height: 44)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        // Non-interactive glass: the interactive variant pulses with light
        // under the Menu's highlight state on iOS 27.
        .glassEffect(.regular, in: .circle)
    }
}
