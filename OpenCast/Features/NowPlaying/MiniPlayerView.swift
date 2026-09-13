import OpenCastCore
import OpenCastPlayback
import SwiftData
import SwiftUI

struct MiniPlayerView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.tabViewBottomAccessoryPlacement) private var tabAccessoryPlacement
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let isNowPlayingPresented: Bool
    let onExpand: () -> Void

    @State private var transportFeedback = 0

    var body: some View {
        let state = appModel.playback.state
        let showsPauseButton = state.showsPauseButton

        if let episode = appModel.playback.currentEpisode {
            HStack(spacing: isInline ? 4 : 8) {
                Button(action: expand) {
                    HStack(spacing: 10) {
                        ArtworkPlaceholder(
                            title: episode.podcastTitle,
                            imageURL: episode.artworkURL?.absoluteString,
                            size: isInline ? 30 : 38,
                            cacheKind: .episode
                        )
                        .accessibilityHidden(true)

                        MiniPlayerMetadataView(
                            title: episode.title,
                            podcastTitle: episode.podcastTitle
                        )
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open Now Playing")
                .accessibilityValue("\(episode.title), \(episode.podcastTitle)")

                Button(action: togglePlayPause) {
                    Group {
                        if state.showsLoadingIndicator {
                            ProgressView()
                        } else {
                            Image(systemName: showsPauseButton ? "pause.fill" : "play.fill")
                                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                        }
                    }
                    .font(dynamicTypeSize.isAccessibilitySize ? .caption : .title3)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: state.showsLoadingIndicator)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showsPauseButton ? "Pause" : "Play")
                .accessibilityInputLabels(showsPauseButton ? ["Pause"] : ["Play"])
                .accessibilityValue(state.accessibilityDescription)

                if !isInline && !dynamicTypeSize.isAccessibilitySize {
                    Button(action: skipForward) {
                        Label(skipForwardLabel, systemImage: "goforward.\(skipForwardSeconds)")
                            .labelStyle(.iconOnly)
                            .font(.title3)
                            .frame(width: 44, height: 44)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, isInline ? 8 : 12)
            .padding(.vertical, isInline ? 0 : 6)
            .sensoryFeedback(.impact(flexibility: .soft), trigger: transportFeedback)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(isInline ? "mini-player-inline" : "mini-player-expanded")
            .accessibilityHidden(isNowPlayingPresented)
            .accessibilityAction(named: "Dismiss Player", dismissPlayer)
        }
    }

    private var isInline: Bool {
        tabAccessoryPlacement == .inline
    }

    private var skipForwardSeconds: Int {
        Int(appModel.playbackSettings.skipForwardOption.seconds.rounded())
    }

    private var skipForwardLabel: String {
        "Skip Forward \(skipForwardSeconds) Seconds"
    }

    private func expand() {
        nowPlayingProbeMark("miniplayer-tap")
        onExpand()
    }

    private func dismissPlayer() {
        appModel.dismissCurrentPlayback(modelContext: modelContext)
    }

    private func togglePlayPause() {
        transportFeedback += 1
        appModel.playback.togglePlayPause()
    }

    private func skipForward() {
        transportFeedback += 1
        appModel.playback.skip(by: appModel.playbackSettings.skipForwardOption.seconds)
    }
}
