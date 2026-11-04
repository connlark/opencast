import OpenCastCore
import OpenCastPlayback
import SwiftData
import SwiftUI

struct MiniPlayerView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(TabAccessoryGeometryStore.self) private var accessoryStore: TabAccessoryGeometryStore?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.tabViewBottomAccessoryPlacement) private var tabAccessoryPlacement
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let onExpand: () -> Void

    @State private var transportFeedback = 0

    var body: some View {
        let state = appModel.playback.state
        let showsPauseButton = state.showsPauseButton

        if let episode = appModel.playback.currentEpisode {
            let playlistSource = appModel.currentPlaylistSource
            let playlistRemainingCount = playlistSource.map {
                appModel.remainingQueuedCount(forPlaylist: $0.playlistID)
            } ?? 0
            let row = TabAccessoryRow(geometry: accessoryGeometry, isInline: isInline)
            let metrics = row.metrics

            HStack(spacing: isInline ? 4 : metrics.controlSpacing) {
                Button(action: expand) {
                    HStack(spacing: isInline ? 10 : metrics.artworkTitleSpacing) {
                        ArtworkPlaceholder(
                            title: episode.podcastTitle,
                            imageURL: episode.artworkURL?.absoluteString,
                            size: isInline ? 30 : metrics.artworkSide,
                            cacheKind: .episode
                        )
                        .accessibilityHidden(true)

                        MiniPlayerMetadataView(
                            title: episode.title,
                            podcastTitle: episode.podcastTitle,
                            playlistSource: isInline ? nil : playlistSource,
                            playlistRemainingCount: playlistRemainingCount,
                            showsSecondaryLine: row != .dense
                        )
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open Now Playing")
                .accessibilityValue(
                    openNowPlayingValue(
                        for: episode,
                        playlistSource: playlistSource,
                        remainingCount: playlistRemainingCount
                    )
                )

                if row == .wide {
                    MiniPlayerScrubber()
                        .frame(width: TabAccessoryRow.scrubberWidth)

                    Button(action: skipBackward) {
                        Label(skipBackwardLabel, systemImage: "gobackward.\(skipBackwardSeconds)")
                            .labelStyle(.iconOnly)
                            .font(.title3)
                            .frame(width: 44, height: 44)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }

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

                if !isInline && (row == .wide || !dynamicTypeSize.isAccessibilitySize) {
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
            .padding(.horizontal, isInline ? 8 : metrics.horizontalPadding)
            .padding(.vertical, isInline ? 0 : metrics.verticalPadding)
            .sensoryFeedback(.impact(flexibility: .soft), trigger: transportFeedback)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(isInline ? "mini-player-inline" : "mini-player-expanded")
            .accessibilityHidden(appModel.isNowPlayingPresented)
            .accessibilityAction(named: "Stop Playback", stopPlayback)
            .onChange(of: accessoryGeometry, initial: true) { _, geometry in
                TabAccessoryRow.log(accessory: "mini-player", geometry: geometry, isInline: isInline)
            }
            .tabAccessoryRowContainer()
        }
    }

    private var isInline: Bool {
        tabAccessoryPlacement == .inline
    }

    /// The accessory's own measured geometry, published by the tab root;
    /// absent outside the tab view.
    private var accessoryGeometry: TabAccessoryGeometry {
        accessoryStore?.geometry ?? .absent
    }

    private func openNowPlayingValue(
        for episode: Episode,
        playlistSource: PlaylistPlaybackSource?,
        remainingCount: Int
    ) -> String {
        guard let playlistSource else {
            return "\(episode.title), \(episode.podcastTitle)"
        }
        return PlaylistPlaybackSourceText.miniPlayerAccessibilityValue(
            title: episode.title,
            name: playlistSource.name,
            remainingCount: remainingCount
        )
    }

    private var skipForwardSeconds: Int {
        Int(appModel.playbackSettings.skipForwardOption.seconds.rounded())
    }

    private var skipForwardLabel: String {
        "Skip Forward \(skipForwardSeconds) Seconds"
    }

    private var skipBackwardSeconds: Int {
        Int(appModel.playbackSettings.skipBackwardOption.seconds.rounded())
    }

    private var skipBackwardLabel: String {
        "Skip Back \(skipBackwardSeconds) Seconds"
    }

    private func expand() {
        nowPlayingProbeMark("miniplayer-tap")
        onExpand()
    }

    private func stopPlayback() {
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

    private func skipBackward() {
        transportFeedback += 1
        appModel.playback.skip(by: -appModel.playbackSettings.skipBackwardOption.seconds)
    }
}
