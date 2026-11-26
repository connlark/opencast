import SwiftUI

struct NowPlayingMoreMenu: View {
    let episode: EpisodeListItemSnapshot?
    let hasTranscript: Bool
    let canShowDescription: Bool
    let descriptionOpensEpisode: Bool
    let canShowShow: Bool
    let playlistSourceName: String?
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
                hasTranscript ? "View Transcript" : "Generate Transcript",
                systemImage: "text.quote",
                action: onTranscriptAction
            )
            if showsPrivateNotes {
                Button("Private Notes", systemImage: "note.text", action: onShowNotes)
                    .accessibilityIdentifier("Menu Private Notes")
            }
            Button(
                descriptionOpensEpisode ? "Go to Episode" : NowPlayingSecondaryPane.showNotes.title,
                systemImage: descriptionOpensEpisode ? "info.circle" : NowPlayingSecondaryPane.showNotes.systemImage,
                action: onShowDescription
            )
            .disabled(!canShowDescription)
            Button("Go to Show", systemImage: "rectangle.stack", action: onShowShow)
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
