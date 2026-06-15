import SwiftData
import SwiftUI

struct NowPlayingView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.modelContext) private var modelContext
    @State private var scrubPosition: TimeInterval = 0
    @State private var isScrubbing = false
    @State private var playPauseFeedback = 0
    @State private var skipFeedback = 0
    @State private var scrubFeedback = 0
    @State private var scrubbingEpisodeID: String?
    @State private var utilitySheet: PlayerUtilitySheet?
    @State private var isVoiceBoostEnabled = true

    let bottomContentPadding: CGFloat
    let topContentPadding: CGFloat
    @Binding var isPeelInteractionActive: Bool
    @Binding var isContentScrolledToTop: Bool
    let isTrackingDismissDrag: Bool
    let prewarmsPeelRenderer: Bool
    let prewarmsPeelSettingsPanel: Bool
    let allowsPeelStart: Bool
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
                        if appModel.replacesNowPlayingArtworkWithPlaybackDiagnostics {
                            NowPlayingPlaybackDiagnosticsView(
                                text: appModel.playback.playbackDiagnosticsText,
                                size: artworkSize
                            )
                        } else {
                            PeelableNowPlayingArtwork(
                                title: episode.podcastTitle,
                                imageURL: episode.artworkURL?.absoluteString,
                                size: artworkSize,
                                voiceBoostEnabled: $isVoiceBoostEnabled,
                                voiceBoostControlEnabled: appModel.playbackSettings.canChangeCurrentEpisodeVoiceBoost,
                                isPeelInteractionActive: $isPeelInteractionActive,
                                prewarmsPeelRenderer: prewarmsPeelRenderer,
                                prewarmsPeelSettingsPanel: prewarmsPeelSettingsPanel,
                                allowsPeelStart: allowsPeelStart
                            )
                        }

                        VStack(spacing: 6) {
                            Button(action: openEpisode) {
                                Text(episode.title)
                                    .font(titleFont)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(titleLineLimit)
                                    .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 0.92 : 0.78)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Opens the episode description")
                            .accessibilityIdentifier("Now Playing Episode Title")

                            Button(action: openPodcast) {
                                Text(episode.podcastTitle)
                                    .font(podcastFont)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(podcastLineLimit)
                                    .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 0.9 : 0.82)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Opens the podcast feed")
                        }
                        .layoutPriority(0)

                        NowPlayingProgressView(
                            duration: appModel.playback.duration,
                            displayedPosition: displayedPosition,
                            scrubPosition: $scrubPosition,
                            onEditingChanged: updateScrubbing
                        )
                        .padding(.top, 4)
                        .layoutPriority(2)

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
                        .padding(.top, transportTopPadding(in: proxy))
                        .layoutPriority(2)

                        NowPlayingUtilityControls(
                            rate: appModel.playback.rate,
                            sleepTimerText: sleepTimerText,
                            onShowSpeed: { utilitySheet = .speed },
                            onShowSleepTimer: { utilitySheet = .sleep }
                        )
                        .padding(.top, utilityTopPadding)
                        .layoutPriority(1)
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
            .scrollDisabled(isTrackingDismissDrag)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                // At rest, a scroll view's top offset is the negative top inset.
                geometry.contentOffset.y <= -geometry.contentInsets.top + 1
            } action: { _, isAtTop in
                isContentScrolledToTop = isAtTop
            }
            .tint(.accentColor)
            .foregroundStyle(.primary)
            .sensoryFeedback(.impact(flexibility: .soft), trigger: playPauseFeedback)
            .sensoryFeedback(.selection, trigger: skipFeedback)
            .sensoryFeedback(.selection, trigger: scrubFeedback)
            .accessibilityAction(.escape) {
                onDismiss()
            }
            .sheet(item: $utilitySheet) { sheet in
                switch sheet {
                case .speed:
                    PlaybackSpeedView()
                        .environment(appModel)
                        .modelContext(modelContext)
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                case .sleep:
                    SleepTimerView()
                        .environment(appModel)
                        .modelContext(modelContext)
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
            .onChange(of: currentEpisodeID) { _, _ in
                // A scrub in flight when the episode changes must not keep displaying
                // the old episode's drag position.
                isScrubbing = false
                scrubPosition = appModel.playback.position
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
        appModel.playback.state == .playing
            || appModel.playback.state == .buffering
            || appModel.playback.state == .loading
    }

    private var currentPodcastID: String? {
        appModel.playback.currentEpisode?.podcastID.rawValue
    }

    private var currentEpisodeID: String? {
        appModel.playback.currentEpisode?.id.rawValue
    }

    private func artworkWidth(in proxy: GeometryProxy) -> CGFloat {
        let availableWidth = proxy.size.width - horizontalPadding * 2
        let availableHeight = max(proxy.size.height - topContentPadding - bottomContentPadding, 280)
        if dynamicTypeSize.isAccessibilitySize {
            let heightConstrainedWidth = availableHeight * (horizontalSizeClass == .regular ? 0.30 : 0.26)
            return min(availableWidth, heightConstrainedWidth, accessibilityArtworkCap(in: proxy))
        }

        let heightConstrainedWidth = availableHeight * (horizontalSizeClass == .regular ? 0.46 : 0.40)
        return min(availableWidth, heightConstrainedWidth, horizontalSizeClass == .regular ? 360 : 300)
    }

    private func contentWidth(in proxy: GeometryProxy) -> CGFloat {
        min(proxy.size.width - horizontalPadding * 2, horizontalSizeClass == .regular ? 500 : 430)
    }

    private var contentSpacing: CGFloat {
        if dynamicTypeSize.isAccessibilitySize {
            return 14
        }

        return 12
    }

    private func transportTopPadding(in proxy: GeometryProxy) -> CGFloat {
        if dynamicTypeSize.isAccessibilitySize {
            return 8
        }

        return proxy.size.height > 780 ? 12 : 10
    }

    private var utilityTopPadding: CGFloat {
        if dynamicTypeSize.isAccessibilitySize {
            return 8
        }

        return 6
    }

    private var titleFont: Font {
        dynamicTypeSize.isAccessibilitySize ? .headline : .title2
    }

    private var podcastFont: Font {
        dynamicTypeSize.isAccessibilitySize ? .subheadline : .title3
    }

    private var titleLineLimit: Int {
        dynamicTypeSize.isAccessibilitySize ? 3 : 2
    }

    private var podcastLineLimit: Int {
        dynamicTypeSize.isAccessibilitySize ? 2 : 1
    }

    private func accessibilityArtworkCap(in proxy: GeometryProxy) -> CGFloat {
        if horizontalSizeClass == .regular {
            return 300
        }

        if proxy.size.height < 700 {
            return 188
        }

        if proxy.size.height < 780 {
            return 220
        }

        return 240
    }

    private func updateScrubbing(_ editing: Bool) {
        if editing {
            scrubbingEpisodeID = currentEpisodeID
            isScrubbing = true
            scrubFeedback += 1
        } else {
            // A release after the episode changed mid-drag must not seek the new
            // episode to a position chosen on the old episode's timeline.
            guard scrubbingEpisodeID == currentEpisodeID else {
                isScrubbing = false
                scrubPosition = appModel.playback.position
                return
            }

            let seekPosition = scrubPosition
            isScrubbing = false
            appModel.playback.seek(to: seekPosition)
        }
    }

    private func retryPlayback() {
        appModel.playback.play()
    }

    private func skipBackward() {
        skipFeedback += 1
        appModel.playback.skip(by: -appModel.playbackSettings.skipBackwardOption.seconds)
    }

    private func togglePlayPause() {
        playPauseFeedback += 1
        appModel.playback.togglePlayPause()
    }

    private func skipForward() {
        skipFeedback += 1
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
