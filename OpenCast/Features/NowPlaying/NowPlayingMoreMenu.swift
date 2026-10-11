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
    let onTranscriptAction: () -> Void
    let onShowNotes: () -> Void
    let onShowDescription: () -> Void
    let onShowShow: () -> Void
    let onShowPlaylist: () -> Void
    let onAddToPlaylist: () -> Void
    let onAddTimestampedNote: () -> Void
    let onAddEpisodeNote: () -> Void
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
            Button("Private Notes", systemImage: "note.text", action: onShowNotes)
                .accessibilityIdentifier("Menu Private Notes")
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
            Menu("Add Private Note", systemImage: "square.and.pencil") {
                Button("Add Timestamped Note", systemImage: "clock", action: onAddTimestampedNote)
                Button("Add Episode Note", systemImage: "note.text", action: onAddEpisodeNote)
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
