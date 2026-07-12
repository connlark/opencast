import OpenCastCore
import OpenCastPlayback
import SwiftData
import SwiftUI

struct MiniPlayerView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.tabViewBottomAccessoryPlacement) private var tabAccessoryPlacement

    let isNowPlayingPresented: Bool
    let onExpand: () -> Void

    @State private var playPauseFeedback = 0

    private static let cornerRadius: CGFloat = 28

    var body: some View {
        let state = appModel.playback.state
        let showsPauseButton = state == .playing || state == .buffering || state == .loading

        if let episode = appModel.playback.currentEpisode {
            miniPlayerChrome {
                HStack(spacing: 12) {
                    Button(action: expand) {
                        HStack(spacing: 10) {
                            ArtworkPlaceholder(
                                title: episode.podcastTitle,
                                imageURL: episode.artworkURL?.absoluteString,
                                size: artworkSize,
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

                    Button(action: togglePlayPause) {
                        Image(systemName: showsPauseButton ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .contentTransition(.symbolEffect(.replace))
                            .animation(.easeOut(duration: 0.2), value: showsPauseButton)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(showsPauseButton ? "Pause" : "Play")
                    .accessibilityValue(state.accessibilityDescription)
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
            }
            .sensoryFeedback(.impact(flexibility: .soft), trigger: playPauseFeedback)
            .accessibilityElement(children: .contain)
            .accessibilityHidden(isNowPlayingPresented)
            .accessibilityAction(named: "Dismiss Player", dismissPlayer)
        }
    }

    private func expand() {
        nowPlayingProbeMark("miniplayer-tap")
        onExpand()
    }

    private func dismissPlayer() {
        appModel.dismissCurrentPlayback(modelContext: modelContext)
    }

    private func togglePlayPause() {
        playPauseFeedback += 1
        appModel.playback.togglePlayPause()
    }

    private var isInTabAccessory: Bool {
        tabAccessoryPlacement != nil
    }

    private var artworkSize: CGFloat {
        isInTabAccessory ? 38 : 42
    }

    private var horizontalPadding: CGFloat {
        isInTabAccessory ? 12 : 14
    }

    private var verticalPadding: CGFloat {
        isInTabAccessory ? 8 : 9
    }

    @ViewBuilder
    private func miniPlayerChrome<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        if isInTabAccessory {
            content()
        } else {
            content()
                .glassEffect(.regular, in: .rect(cornerRadius: Self.cornerRadius))
        }
    }
}
