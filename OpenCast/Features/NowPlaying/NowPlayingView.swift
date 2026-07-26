import SwiftData
import SwiftUI
import OpenCastPlayback

struct NowPlayingView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.modelContext) private var modelContext
    @State private var playPauseFeedback = 0
    @State private var skipFeedback = 0
    @State private var autoSkipFeedback = 0
    @State private var utilitySheet: PlayerUtilitySheet?
    @State private var isVoiceBoostEnabled = true
    @State private var showsAutoSkipPill = false
    @State private var displayedAutoSkipEventSequence = 0
    @State private var remoteEstimateRequest: RemoteTranscriptionStartPreviewRequest?
    @State private var adDetectionModePromptEpisode: EpisodeListItemSnapshot?

    let bottomContentPadding: CGFloat
    let topContentPadding: CGFloat
    let moreMenuTopPadding: CGFloat
    @Binding var isSoundLabInteractionActive: Bool
    @Binding var isContentScrolledToTop: Bool
    let isTrackingDismissDrag: Bool
    let onDismiss: () -> Void
    let onOpenEpisode: () -> Void
    let onOpenPodcast: () -> Void

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                if let episode = appModel.playback.currentEpisode {
                    let artworkSize = artworkWidth(in: proxy)
                    VStack(spacing: contentSpacing) {
                        if appModel.replacesNowPlayingArtworkWithPlaybackDiagnostics {
                            NowPlayingPlaybackDiagnosticsView(
                                text: appModel.playback.playbackDiagnosticsText
                                    + appModel.playbackSourceIdentityDiagnostics,
                                size: artworkSize
                            )
                        } else {
                            NowPlayingSoundLabArtwork(
                                title: episode.podcastTitle,
                                imageURL: episode.artworkURL?.absoluteString,
                                size: artworkSize,
                                voiceBoostEnabled: $isVoiceBoostEnabled,
                                voiceBoostControlEnabled: appModel.playbackSettings.canChangeCurrentEpisodeVoiceBoost,
                                onAdFreePassAction: startAdFreePass,
                                onTranscribeRemotely: presentRemoteTranscriptionEstimate,
                                onShowTranscript: performTranscriptAction,
                                onAdFreePassBackgroundProbe: startAdFreePassBackgroundProbe,
                                isSoundLabInteractionActive: $isSoundLabInteractionActive,
                                isCardDismissDragActive: isTrackingDismissDrag
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
                            .disabled(!canOpenCurrentEpisode)
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
                            .disabled(!canOpenCurrentPodcast)
                            .accessibilityHint("Opens the show in your library")
                            .accessibilityIdentifier("Now Playing Podcast Title")
                        }
                        .layoutPriority(0)

                        ZStack(alignment: .top) {
                            NowPlayingProgressSection()
                                .padding(.top, accessibilityReduceMotion ? 30 : 0)

                            if showsAutoSkipPill {
                                NowPlayingAutoSkipPill(onUndo: undoLastAutoSkip)
                                    .transition(.opacity)
                                    .offset(y: accessibilityReduceMotion ? 0 : -28)
                            }
                        }
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
                            .transition(.opacity)
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
                    .animation(
                        accessibilityReduceMotion ? nil : .easeOut(duration: 0.2),
                        value: isPlaybackFailed
                    )
                } else {
                    ContentUnavailableView("Nothing Playing", systemImage: "play.circle")
                        .padding()
                }
            }
            .scrollIndicators(.hidden)
            .scrollDisabled(isTrackingDismissDrag)
            .overlay(alignment: .topTrailing) {
                if appModel.playback.currentEpisode != nil {
                    NowPlayingMoreMenu(
                        hasTranscript: hasCompletedTranscript,
                        canShowDescription: canOpenCurrentEpisode,
                        canShowShow: canOpenCurrentPodcast,
                        onTranscriptAction: performTranscriptAction,
                        onShowDescription: openEpisode,
                        onShowShow: openPodcast
                    )
                    .padding(.top, moreMenuTopPadding)
                    .padding(.trailing, 20)
                    .opacity(isSoundLabInteractionActive ? 0 : 1)
                    .allowsHitTesting(!isSoundLabInteractionActive)
                    .animation(.easeOut(duration: 0.15), value: isSoundLabInteractionActive)
                }
            }
            .overlay(alignment: .top) {
                if let remoteTranscriptionPresentation {
                    NowPlayingRemoteTranscriptionToast(
                        presentation: remoteTranscriptionPresentation,
                        onCancel: appModel.remoteTranscription.cancel
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, moreMenuTopPadding + 48)
                    .transition(
                        accessibilityReduceMotion
                            ? .opacity
                            : .move(edge: .top).combined(with: .opacity)
                    )
                } else if let transcriptionRequest {
                    NowPlayingTranscriptionToast(
                        request: transcriptionRequest,
                        onOpenTranscript: openTranscriptFromToast,
                        onDismiss: dismissTranscriptionToast
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, moreMenuTopPadding + 48)
                    .transition(
                        accessibilityReduceMotion
                            ? .opacity
                            : .move(edge: .top).combined(with: .opacity)
                    )
                }
            }
            .animation(
                accessibilityReduceMotion ? .easeOut(duration: 0.2) : .bouncy,
                value: transcriptionRequest?.id
            )
            .animation(
                accessibilityReduceMotion ? .easeOut(duration: 0.2) : .bouncy,
                value: remoteTranscriptionPresentation != nil
            )
            .onScrollGeometryChange(for: Bool.self) { geometry in
                // At rest, a scroll view's top offset is the negative top inset.
                geometry.contentOffset.y <= -geometry.contentInsets.top + 1
            } action: { _, isAtTop in
                isContentScrolledToTop = isAtTop
            }
            .tint(.accentColor)
            .foregroundStyle(.primary)
            .adDetectionModeDialog(episode: $adDetectionModePromptEpisode)
            .sensoryFeedback(.impact(flexibility: .soft), trigger: playPauseFeedback)
            .sensoryFeedback(.selection, trigger: skipFeedback)
            .sensoryFeedback(.impact(flexibility: .soft), trigger: autoSkipFeedback)
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
                case .transcript:
                    NavigationStack {
                        if let currentEpisodeID {
                            EpisodeTranscriptView(episodeID: currentEpisodeID)
                        } else {
                            ContentUnavailableView("Nothing Playing", systemImage: "play.circle")
                        }
                    }
                    .environment(appModel)
                    .modelContext(modelContext)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                }
            }
            .sheet(item: $remoteEstimateRequest) { request in
                RemoteTranscriptionConsumptionPreviewSheet(request: request) {
                    startRemoteTranscription(for: request)
                }
                .environment(appModel)
                .modelContext(modelContext)
            }
            .onAppear {
                showAutoSkipPillIfNeeded(for: appModel.playback.lastAutoSkipEvent)
            }
            .onChange(of: appModel.playbackSettings.isVoiceBoostEnabled) { _, _ in
                syncVoiceBoostEnabledFromStore()
            }
            .onChange(of: appModel.playback.lastAutoSkipEvent) { _, event in
                showAutoSkipPillIfNeeded(for: event)
            }
            .onChange(of: isVoiceBoostEnabled) { _, newValue in
                applyVoiceBoostEnabled(newValue)
            }
            .onChange(of: currentEpisodeID) { _, _ in
                showsAutoSkipPill = false
                displayedAutoSkipEventSequence = 0
                showAutoSkipPillIfNeeded(for: appModel.playback.lastAutoSkipEvent)
            }
            .task(id: currentEpisodeID) {
                syncVoiceBoostEnabledFromStore()
            }
            .task(id: displayedAutoSkipEventSequence) {
                await dismissAutoSkipPillAfterDelay()
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

    private var showsPauseButton: Bool {
        appModel.playback.state == .playing
            || appModel.playback.state == .buffering
            || appModel.playback.state == .loading
    }

    private var isPlaybackFailed: Bool {
        if case .failed = appModel.playback.state {
            true
        } else {
            false
        }
    }

    private var currentPodcastID: String? {
        appModel.playback.currentEpisode?.podcastID.rawValue
    }

    private var currentEpisodeID: String? {
        appModel.playback.currentEpisode?.id.rawValue
    }

    private var canOpenCurrentEpisode: Bool {
        guard let currentEpisodeID else {
            return false
        }
        return appModel.library.episode(with: currentEpisodeID) != nil
            || appModel.downloads.record(for: currentEpisodeID) != nil
    }

    private var canOpenCurrentPodcast: Bool {
        guard let currentPodcastID else {
            return false
        }
        return appModel.library.isActivelySubscribed(to: currentPodcastID)
    }

    private var hasCompletedTranscript: Bool {
        guard let currentEpisodeID,
              let record = appModel.transcriptions.record(for: currentEpisodeID)
        else {
            return false
        }
        return record.state == .completed && record.transcriptRelativePath != nil
    }

    private var transcriptionRequest: EpisodeTranscriptionRequest? {
        guard appModel.transcriptionRequests.isPresented,
              let request = appModel.transcriptionRequests.request,
              request.episodeID == currentEpisodeID
        else {
            return nil
        }
        return request
    }

    private var remoteTranscriptionPresentation: RemoteTranscriptionStatusPresentation? {
        guard appModel.remoteTranscriptionPurchases.isSurfaceVisible,
              let currentEpisodeID,
              let phase = appModel.remoteTranscription.store.phase(for: currentEpisodeID),
              !phase.isTerminal
        else {
            return nil
        }
        return RemoteTranscriptionStatusPresentation.make(phase: phase)
    }

    private func performTranscriptAction() {
        guard let currentEpisodeID else {
            return
        }
        guard let record = appModel.transcriptions.record(for: currentEpisodeID),
              record.state == .completed,
              let relativePath = record.transcriptRelativePath
        else {
            appModel.requestTranscriptForCurrentEpisode(modelContext: modelContext)
            return
        }

        Task {
            do {
                _ = try await appModel.transcriptions.loadDocument(for: currentEpisodeID)
                guard canCompleteTranscriptAction(
                    episodeID: currentEpisodeID,
                    relativePath: relativePath
                ) else {
                    return
                }
                utilitySheet = .transcript
            } catch {
                guard canCompleteTranscriptAction(
                    episodeID: currentEpisodeID,
                    relativePath: relativePath
                ) else {
                    return
                }
                appModel.transcriptions.markTranscriptDocumentUnavailable(
                    episodeID: currentEpisodeID,
                    modelContext: modelContext
                )
                appModel.requestTranscriptForCurrentEpisode(modelContext: modelContext)
            }
        }
    }

    private func canCompleteTranscriptAction(
        episodeID: String,
        relativePath: String
    ) -> Bool {
        guard appModel.isNowPlayingPresented,
              utilitySheet == nil,
              currentEpisodeID == episodeID,
              let record = appModel.transcriptions.record(for: episodeID)
        else {
            return false
        }
        return record.state == .completed && record.transcriptRelativePath == relativePath
    }

    private func dismissTranscriptionToast() {
        guard let transcriptionRequest else {
            return
        }
        appModel.dismissTranscriptionRequest(id: transcriptionRequest.id)
    }

    private func openTranscriptFromToast() {
        guard transcriptionRequest?.phase == .completed else {
            return
        }
        dismissTranscriptionToast()
        performTranscriptAction()
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

    private func startAdFreePass() {
        adDetectionModePromptEpisode = appModel.startOrContinueAdFreePassForCurrentEpisodeResolvingMode(
            modelContext: modelContext
        )
    }

    private func presentRemoteTranscriptionEstimate() {
        guard appModel.remoteTranscriptionPurchases.isSurfaceVisible,
              !appModel.remoteTranscription.store.hasActiveRequest,
              let currentEpisodeID,
              !appModel.transcriptions.hasCompletedTranscript(for: currentEpisodeID)
        else {
            return
        }

        remoteEstimateRequest = appModel.remoteTranscriptionStartPreviewRequestForCurrentEpisode()
    }

    private func startRemoteTranscription(for request: RemoteTranscriptionStartPreviewRequest) {
        guard request.episodeID == currentEpisodeID else {
            return
        }

        appModel.startRemoteTranscriptionForCurrentEpisode(modelContext: modelContext)
    }

    private func startAdFreePassBackgroundProbe() {
        #if DEBUG
        AdFreePassBackgroundProbe.startFromUserAction()
        #endif
    }

    private func undoLastAutoSkip() {
        appModel.undoLastAutoSkip()
        withAnimation(.easeOut(duration: 0.2)) {
            showsAutoSkipPill = false
        }
    }

    private func showAutoSkipPillIfNeeded(for event: PlaybackAutoSkipEvent?) {
        guard let event, event.sequence > displayedAutoSkipEventSequence else {
            return
        }

        displayedAutoSkipEventSequence = event.sequence
        showAutoSkipPill()
    }

    private func showAutoSkipPill() {
        autoSkipFeedback += 1
        UIAccessibility.post(notification: .announcement, argument: "Skipped promo")
        withAnimation(.easeOut(duration: 0.16)) {
            showsAutoSkipPill = true
        }
    }

    private func dismissAutoSkipPillAfterDelay() async {
        guard displayedAutoSkipEventSequence > 0 else {
            return
        }

        do {
            try await Task.sleep(for: .milliseconds(2500))
        } catch is CancellationError {
            return
        } catch {
            return
        }

        withAnimation(.easeOut(duration: 0.2)) {
            showsAutoSkipPill = false
        }
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
