import SwiftUI

struct NowPlayingView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.modelContext) private var modelContext
    @State private var scrubPosition: TimeInterval = 0
    @State private var isScrubbing = false
    @State private var utilitySheet: PlayerUtilitySheet?
    @State private var isVoiceBoostEnabled = true

    let bottomContentPadding: CGFloat
    let topContentPadding: CGFloat
    @Binding var isPeelInteractionActive: Bool
    let prewarmsPeelRenderer: Bool
    let prewarmsPeelSettingsPanel: Bool
    let onDismiss: () -> Void
    let onOpenEpisode: () -> Void
    let onOpenPodcast: () -> Void

    private var displayedPosition: TimeInterval {
        isScrubbing ? scrubPosition : appModel.playback.position
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                if let episode = appModel.playback.currentEpisode {
                    let artworkSize = artworkWidth(in: proxy)
                    VStack(spacing: contentSpacing) {
                        PeelableNowPlayingArtwork(
                            title: episode.podcastTitle,
                            imageURL: episode.artworkURL?.absoluteString,
                            size: artworkSize,
                            voiceBoostEnabled: $isVoiceBoostEnabled,
                            voiceBoostControlEnabled: appModel.playbackSettings.canChangeCurrentEpisodeVoiceBoost,
                            isPeelInteractionActive: $isPeelInteractionActive,
                            prewarmsPeelRenderer: prewarmsPeelRenderer,
                            prewarmsPeelSettingsPanel: prewarmsPeelSettingsPanel
                        )

                        VStack(spacing: 6) {
                            Button(action: openEpisode) {
                                Text(episode.title)
                                    .font(.title2)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                                    .minimumScaleFactor(0.78)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Opens the episode description")

                            Button(action: openPodcast) {
                                Text(episode.podcastTitle)
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.82)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Opens the podcast feed")
                        }

                        NowPlayingProgressView(
                            duration: appModel.playback.duration,
                            displayedPosition: displayedPosition,
                            scrubPosition: $scrubPosition,
                            onEditingChanged: updateScrubbing
                        )
                        .padding(.top, 4)

                        if case .failed(let message) = appModel.playback.state {
                            VStack(spacing: 8) {
                                Label("Playback Failed", systemImage: "exclamationmark.triangle")
                                    .font(.headline)

                                Text(message)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)

                                Button("Retry", systemImage: "arrow.clockwise", action: retryPlayback)
                                    .buttonStyle(.glass)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 2)
                            .accessibilityElement(children: .combine)
                        }

                        NowPlayingTransportControls(
                            skipBackwardInterval: appModel.playbackSettings.skipBackwardOption.seconds,
                            skipForwardInterval: appModel.playbackSettings.skipForwardOption.seconds,
                            showsPauseButton: showsPauseButton,
                            playbackStateText: appModel.playback.state.accessibilityDescription,
                            onSkipBackward: skipBackward,
                            onTogglePlayPause: togglePlayPause,
                            onSkipForward: skipForward
                        )
                        .equatable()
                        .padding(.top, transportTopPadding(in: proxy))

                        NowPlayingUtilityControls(
                            rate: appModel.playback.rate,
                            sleepTimerText: sleepTimerText,
                            onShowSpeed: { utilitySheet = .speed },
                            onShowSleepTimer: { utilitySheet = .sleep }
                        )
                        .equatable()
                        .padding(.top, utilityTopPadding)
                    }
                    .frame(maxWidth: contentWidth(in: proxy))
                    .padding(.horizontal, horizontalPadding)
                    .padding(.top, topContentPadding)
                    .padding(.bottom, bottomContentPadding)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: proxy.size.height, alignment: .top)
                } else {
                    ContentUnavailableView("Nothing Playing", systemImage: "play.circle")
                        .padding()
                }
            }
            .scrollIndicators(.hidden)
            .scrollDisabled(true)
            .tint(.accentColor)
            .foregroundStyle(.primary)
            .accessibilityAction(.escape) {
                onDismiss()
            }
            .sheet(item: $utilitySheet) { sheet in
                switch sheet {
                case .speed:
                    PlaybackSpeedView()
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                case .sleep:
                    SleepTimerView()
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                }
            }
            .onAppear {
                scrubPosition = appModel.playback.position
            }
            .onChange(of: appModel.playback.position) { _, newPosition in
                guard !isScrubbing else {
                    return
                }
                scrubPosition = newPosition
            }
            .onChange(of: appModel.playbackSettings.isVoiceBoostEnabled) { _, _ in
                syncVoiceBoostEnabledFromStore()
            }
            .onChange(of: isVoiceBoostEnabled) { _, newValue in
                applyVoiceBoostEnabled(newValue)
            }
            .task(id: currentEpisodeID) {
                syncVoiceBoostEnabledFromStore()
            }
            // The alert API needs a Bool binding because the presented String is not Identifiable.
            .alert(
                "Sound Lab Error",
                isPresented: Binding(
                    get: { appModel.playbackSettings.lastErrorMessage != nil },
                    set: { if !$0 { appModel.playbackSettings.clearLastError() } }
                ),
                presenting: appModel.playbackSettings.lastErrorMessage
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { message in
                Text(message)
            }
        }
    }

    private var horizontalPadding: CGFloat {
        horizontalSizeClass == .regular ? 36 : 24
    }

    private var sleepTimerText: String {
        guard let endsAt = appModel.playback.sleepTimerEndsAt else {
            return "Off"
        }

        let remaining = endsAt.timeIntervalSinceNow
        if remaining <= 0 {
            return "Off"
        }

        return "-\(remaining.formattedPlaybackDuration)"
    }

    private var showsPauseButton: Bool {
        appModel.playback.state == .playing || appModel.playback.state == .buffering
    }

    private var currentPodcastID: String? {
        appModel.playback.currentEpisode?.podcastID.rawValue
    }

    private var currentEpisodeID: String? {
        appModel.playback.currentEpisode?.id.rawValue
    }

    private func artworkWidth(in proxy: GeometryProxy) -> CGFloat {
        let availableWidth = proxy.size.width - horizontalPadding * 2
        if dynamicTypeSize.isAccessibilitySize {
            return min(availableWidth, horizontalSizeClass == .regular ? 320 : 270)
        }

        let heightConstrainedWidth = proxy.size.height * (horizontalSizeClass == .regular ? 0.42 : 0.35)
        return min(availableWidth, heightConstrainedWidth, horizontalSizeClass == .regular ? 360 : 300)
    }

    private func contentWidth(in proxy: GeometryProxy) -> CGFloat {
        min(proxy.size.width - horizontalPadding * 2, horizontalSizeClass == .regular ? 500 : 430)
    }

    private var contentSpacing: CGFloat {
        if dynamicTypeSize.isAccessibilitySize {
            return 18
        }

        return 12
    }

    private func transportTopPadding(in proxy: GeometryProxy) -> CGFloat {
        if dynamicTypeSize.isAccessibilitySize {
            return 16
        }

        return proxy.size.height > 780 ? 12 : 10
    }

    private var utilityTopPadding: CGFloat {
        if dynamicTypeSize.isAccessibilitySize {
            return 16
        }

        return 6
    }

    private func updateScrubbing(_ editing: Bool) {
        if editing {
            scrubPosition = appModel.playback.position
            isScrubbing = true
        } else {
            isScrubbing = false
            appModel.playback.seek(to: scrubPosition)
        }
    }

    private func retryPlayback() {
        appModel.playback.play()
    }

    private func skipBackward() {
        appModel.playback.skip(by: -appModel.playbackSettings.skipBackwardOption.seconds)
    }

    private func togglePlayPause() {
        appModel.playback.togglePlayPause()
    }

    private func skipForward() {
        appModel.playback.skip(by: appModel.playbackSettings.skipForwardOption.seconds)
    }

    private func openEpisode() {
        onOpenEpisode()
    }

    private func openPodcast() {
        onOpenPodcast()
    }

    private func syncVoiceBoostEnabledFromStore() {
        isVoiceBoostEnabled = appModel.playbackSettings.isVoiceBoostEnabled
    }

    private func applyVoiceBoostEnabled(_ isEnabled: Bool) {
        guard let currentEpisodeID else {
            syncVoiceBoostEnabledFromStore()
            return
        }

        guard appModel.playbackSettings.isVoiceBoostEnabled != isEnabled
            || appModel.playbackSettings.currentEpisodeID != currentEpisodeID
        else {
            return
        }

        let didUpdate = appModel.setVoiceBoostEnabled(
            isEnabled,
            forEpisodeID: currentEpisodeID,
            podcastID: currentPodcastID,
            modelContext: modelContext
        )
        if !didUpdate {
            syncVoiceBoostEnabledFromStore()
        }
    }
}
