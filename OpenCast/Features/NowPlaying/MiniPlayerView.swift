import OpenCastPlayback
import SwiftUI

struct MiniPlayerView: View {
    @Environment(OpenCastAppModel.self) private var appModel

    let isNowPlayingPresented: Bool
    let onExpand: () -> Void

    var body: some View {
        let state = appModel.playback.state
        let showsPauseButton = state == .playing || state == .buffering

        if let episode = appModel.playback.currentEpisode {
            VStack(spacing: 0) {
                MiniPlayerProgressBar()

                HStack(spacing: 12) {
                    Button(action: expand) {
                        HStack(spacing: 10) {
                            ArtworkPlaceholder(
                                title: episode.podcastTitle,
                                imageURL: episode.artworkURL?.absoluteString,
                                size: 42,
                                cacheKind: .episode
                            )

                            Text("\(episode.title) - \(episode.podcastTitle)")
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open Now Playing")
                    .accessibilityValue("\(episode.title), \(episode.podcastTitle)")

                    Button(action: appModel.playback.togglePlayPause) {
                        Image(systemName: showsPauseButton ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(showsPauseButton ? "Pause" : "Play")
                    .accessibilityValue(state.accessibilityDescription)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
            }
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 0))
            .overlay(alignment: .top) {
                Divider()
            }
            .accessibilityElement(children: .contain)
            .accessibilityHidden(isNowPlayingPresented)
        }
    }

    private func expand() {
        nowPlayingProbeMark("miniplayer-tap")
        onExpand()
    }
}
