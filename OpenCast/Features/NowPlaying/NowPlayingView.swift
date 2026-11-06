import OpenCastCore
import SwiftData
import SwiftUI

struct NowPlayingView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.modelContext) private var modelContext
    @State private var playPauseFeedback = 0
    @State private var skipFeedback = 0
    @State private var notePlaybackSession: EpisodeNotePlaybackSession?
    @State private var noteDraft: EpisodeNoteDraft?
    @State private var utilitySheet: PlayerUtilitySheet?
    @State private var soundLabHandoff: PlayerUtilitySheet.Handoff?
    @State private var isVoiceBoostEnabled = true
    @State private var remoteEstimateRequest: RemoteTranscriptionStartPreviewRequest?
    @State private var remoteTranscriptionStartErrorMessage: String?
    @State private var adDetectionModePromptEpisode: EpisodeListItemSnapshot?
    @State private var noticeGate = AnalysisKeyNoticeGate()
    @State private var naturalContentHeight: CGFloat?
    @State private var contentMeasurements = NowPlayingContentMeasurements()
    /// Laptop's controls below the band, without an expanded pane.
    @State private var foldedControlsHeight: CGFloat?
    /// The visible toast's height, so its occlusion check uses its real
    /// bounds; both toasts are at least this tall before the first reading.
    @State private var toastHeight: CGFloat = 60
    @State private var scrollPosition = ScrollPosition(edge: .top)
    /// Laptop's controls scroll on their own below the band.
    @State private var controlsScrollPosition = ScrollPosition(edge: .top)
    @State private var scrolledAwayAreas: Set<ScrollArea> = []
    @State private var secondaryPaneFrames: [SecondaryPaneSlot: CGRect] = [:]
    @State private var isSecondaryPaneExpanded = false
    /// The arrangement's pane style as it stands now, for work that finishes
    /// after an await (a captured view value would be the old arrangement).
    @State private var livePaneStyle = NowPlayingSecondaryPaneStyle.entryPointsOnly
    @SceneStorage(NowPlayingSecondaryPane.sceneStorageKey) private var storedSecondaryPane: String?
    @ScaledMetric(relativeTo: .body) private var playButtonScaledDiameter = NowPlayingTransportControls.playButtonBaseDiameter

    /// Today's card, or the player across a foldable scene's window-sized
    /// surface; a split places each half from its own allocation instead.
    let cardGeometry: NowPlayingCardGeometry
    let arrangement: NowPlayingArrangement
    let surface: NowPlayingSurface
    @Binding var isSoundLabInteractionActive: Bool
    @Binding var isContentScrolledToTop: Bool
    /// Global frames where a drag belongs to the secondary pane, never to
    /// the card's dismiss drag.
    @Binding var dismissDragExcludedFrames: [CGRect]
    let isTrackingDismissDrag: Bool
    let onDismiss: () -> Void
    let onOpenEpisode: () -> Void
    let onOpenPodcast: () -> Void
    let onOpenPlaylist: () -> Void
    let onStopPlayback: () -> Void

    fileprivate enum ScrollArea {
        case player
        case media
        case controls
    }

    fileprivate enum SecondaryPaneSlot {
        case beside
        case inline
    }

    // The presenters and the player's state live here, above the switch
    // between arrangements, so a pose change re-lays the player out without
    // dropping a sheet, an alert or a draft.
    var body: some View {
        GeometryReader { proxy in
            arrangedContent(size: proxy.size)
                .tint(.accentColor)
                .foregroundStyle(.primary)
                .adDetectionModeDialog(episode: $adDetectionModePromptEpisode)
                .analysisKeyNotice(gate: noticeGate)
                .sensoryFeedback(.impact(flexibility: .soft), trigger: playPauseFeedback)
                .sensoryFeedback(.selection, trigger: skipFeedback)
                .accessibilityAction(.escape) {
                    onDismiss()
                }
                .sheet(item: $noteDraft, onDismiss: resumePlaybackAfterNote) { draft in
                    AddEpisodeNoteSheet(draft: draft)
                        .modelContext(modelContext)
                }
                .sheet(item: $utilitySheet, onDismiss: completeSoundLabHandoff) { sheet in
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
                    case .upNext:
                        UpNextQueueView()
                            .environment(appModel)
                            .modelContext(modelContext)
                            .presentationDetents([.medium, .large])
                            .presentationDragIndicator(.visible)
                    case .chapters:
                        NowPlayingChaptersView()
                            .environment(appModel)
                            .modelContext(modelContext)
                            .presentationDetents([.medium, .large])
                            .presentationDragIndicator(.visible)
                    case .notes:
                        NavigationStack {
                            if let episode = appModel.playback.currentEpisode {
                                EpisodeNotesList(episode: EpisodeListItemSnapshot(episode: episode)) { timestamp in
                                    playNote(at: timestamp, episodeID: episode.id.rawValue)
                                }
                                .navigationTitle("Private Notes")
                                .navigationSubtitle(episode.title)
                                .navigationBarTitleDisplayMode(.inline)
                                .accessibilityAction(.escape) { utilitySheet = nil }
                            } else {
                                ContentUnavailableView("Nothing Playing", systemImage: "play.circle")
                            }
                        }
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
                    case .soundLab:
                        NowPlayingSoundLabPanelHost(
                            presentation: .sheet,
                            voiceBoostEnabled: $isVoiceBoostEnabled,
                            voiceBoostControlEnabled: appModel.playbackSettings.canChangeCurrentEpisodeVoiceBoost,
                            onAdFreePassAction: handOffAdFreePass,
                            onTranscribeRemotely: handOffRemoteTranscriptionEstimate,
                            onTranscriptAction: handOffTranscriptAction,
                            onAdFreePassBackgroundProbe: startAdFreePassBackgroundProbe
                        )
                        .environment(appModel)
                        .alert(
                            "Sound Lab Error",
                            item: soundLabError(whileSoundLabSheetShown: true)
                        ) { _ in
                        } message: { message in
                            Text(message)
                        }
                        .accessibilityAction(.escape) { utilitySheet = nil }
                        .presentationDetents([.medium, .large])
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
                .alert(
                    "Couldn’t Start Transcription",
                    item: $remoteTranscriptionStartErrorMessage
                ) { _ in
                } message: { message in
                    Text(message)
                }
                .onChange(of: appModel.isNowPlayingPresented) { _, isPresented in
                    if !isPresented { resetPresentation() }
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
                .onChange(of: arrangement.paneStyle, initial: true) { _, style in
                    livePaneStyle = style
                }
                .alert(
                    "Sound Lab Error",
                    item: soundLabError(whileSoundLabSheetShown: false)
                ) { _ in
                } message: { message in
                    Text(message)
                }
        }
    }

    /// Laptop's stack split around its band, or one container for the card,
    /// the split and the tall open display: the player is its first child in
    /// all three, so a change between them moves the player without
    /// rebuilding it.
    @ViewBuilder
    private func arrangedContent(size: CGSize) -> some View {
        if isFoldedLayout,
           let fold = cardGeometry.horizontalFold,
           let episode = appModel.playback.currentEpisode {
            foldedPlayer(episode: episode, fold: fold, size: size)
        } else {
            let allocations = NowPlayingAllocations(
                arrangement: arrangement,
                bounds: size,
                safeAreaInsets: surface.safeAreaInsets
            )
            let container = NowPlayingArrangementContainer(allocations: allocations)
            container {
                playerColumn(geometry: playerGeometry(in: allocations.player), size: allocations.player.size)

                if let pane = allocations.pane {
                    NowPlayingSecondaryPaneView(
                        selection: secondaryPaneSelection,
                        content: secondaryPresentation.content,
                        contentInsets: surface.paneGeometry(allocation: pane).contentInsets
                    )
                    .reportsSecondaryPaneFrame(slot: .beside, update: updateSecondaryPaneFrame)
                }
            }
        }
    }

    /// Today's card where the arrangement is the card; on a window-sized
    /// surface, the player placed from its allocation.
    private func playerGeometry(in allocation: CGRect) -> NowPlayingCardGeometry {
        arrangement.usesWindowSizedSurface ? surface.playerGeometry(allocation: allocation) : cardGeometry
    }

    /// The whole stack in one scroll view: today's card, the player beside
    /// the pane, and the tall open display with the pane's row below the
    /// controls.
    @ViewBuilder
    private func playerColumn(geometry: NowPlayingCardGeometry, size: CGSize) -> some View {
        let metrics = NowPlayingContentMetrics(
            containerSize: size,
            cardGeometry: geometry,
            dynamicTypeSize: dynamicTypeSize,
            horizontalSizeClass: horizontalSizeClass,
            measurements: contentMeasurements
        )
        let presentation = secondaryPresentation
        let paneHeight = NowPlayingSecondaryPanePresentation.inlineHeight(
            viewportHeight: size.height - geometry.contentInsets.top - geometry.contentInsets.bottom
        )
        let paneAllowance = presentation.isExpanded ? paneHeight + metrics.contentSpacing : 0
        // Everything in the stack that is not a measured row.
        let unmeasuredStackHeight = metrics.artworkSize
            + metrics.titleBlockTopSpacer
            + metrics.progressSectionTopSpacer
            + paneAllowance
        ScrollView {
            if let episode = appModel.playback.currentEpisode {
                VStack(spacing: metrics.contentSpacing) {
                    artwork(
                        for: episode,
                        size: metrics.artworkSize,
                        openContext: NowPlayingSoundLabOpenPanel.CardContext(
                            cardGeometry: geometry,
                            contentWidth: metrics.contentWidth,
                            viewport: CGRect(origin: .zero, size: size)
                        )
                    )

                    titleBlock(for: episode, metrics: metrics)
                        .padding(.top, metrics.titleBlockTopSpacer)
                        .layoutPriority(0)

                    progressSection(for: episode)
                        .padding(.top, metrics.progressSectionTopSpacer)
                        .layoutPriority(2)

                    failureBlock

                    transport(containerHeight: size.height)

                    utilityRow(width: metrics.contentWidth)

                    secondaryDisclosure(presentation, paneHeight: paneHeight)
                }
                .onGeometryChange(for: CGFloat.self) { geometry in
                    geometry.size.height - unmeasuredStackHeight
                } action: { height in
                    // Pixel rounding of the artwork moves this by a fraction
                    // of a point; only a real change in the rows refits it.
                    updateMeasurement(\.rowsHeight, to: height, tolerance: 1)
                }
                .frame(maxWidth: metrics.contentWidth)
                .padding(.leading, metrics.leadingPadding)
                .padding(.trailing, metrics.trailingPadding)
                .padding(.top, metrics.topContentPadding)
                .padding(.bottom, metrics.bottomContentPadding)
                // Measured before the min-height frame and without the
                // source pill, so showing the pill never moves this value.
                .onGeometryChange(for: CGFloat.self) { geometry in
                    geometry.size.height
                } action: { height in
                    updateNaturalContentHeight(height)
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: metrics.containerHeight, alignment: .top)
                .overlay(alignment: .bottom) {
                    sourcePill(
                        spareHeight: naturalContentHeight.map { metrics.containerHeight - $0 },
                        metrics: metrics,
                        bottomPadding: metrics.bottomContentPadding
                    )
                }
                .animation(
                    accessibilityReduceMotion ? nil : .easeOut(duration: 0.2),
                    value: isPlaybackFailed
                )
            } else if let finishedPlaybackPresentation = appModel.finishedPlaybackPresentation {
                FinishedPlaybackView(
                    presentation: finishedPlaybackPresentation,
                    metrics: metrics,
                    onReplay: replayFinishedPlayback,
                    onDone: onDismiss
                )
            } else {
                ContentUnavailableView("Nothing Playing", systemImage: "play.circle")
                    .padding()
            }
        }
        .scrollIndicators(.hidden)
        .scrollPosition($scrollPosition)
        .scrollDisabled(isTrackingDismissDrag)
        .tracksScrolledToTop(area: .player, update: updateScrolledToTop)
        .coordinateSpace(.named(NowPlayingSoundLabOpenPanel.CardContext.coordinateSpaceName))
        .overlay(alignment: .topLeading) {
            moreMenu(geometry: geometry)
        }
        .overlay(alignment: .top) {
            toast(geometry: geometry)
        }
        .animation(
            accessibilityReduceMotion ? .easeOut(duration: 0.2) : .bouncy,
            value: transcriptionRequest?.id
        )
        .animation(
            accessibilityReduceMotion ? .easeOut(duration: 0.2) : .bouncy,
            value: remoteTranscriptionPresentation != nil
        )
    }

    /// Laptop: one card across the band, the media in the viewport above it
    /// and the controls in the viewport below it. Each scrolls on its own and
    /// is clipped at the band.
    @ViewBuilder
    private func foldedPlayer(episode: Episode, fold: ClosedRange<CGFloat>, size: CGSize) -> some View {
        let metrics = NowPlayingContentMetrics(
            containerSize: size,
            cardGeometry: cardGeometry,
            dynamicTypeSize: dynamicTypeSize,
            horizontalSizeClass: horizontalSizeClass,
            measurements: contentMeasurements
        )
        let presentation = secondaryPresentation
        let paneHeight = NowPlayingSecondaryPanePresentation.inlineHeight(
            viewportHeight: size.height - fold.upperBound - cardGeometry.contentInsets.bottom
        )
        let paneAllowance = presentation.isExpanded ? paneHeight + metrics.contentSpacing : 0
        let layout = NowPlayingFoldedLayout(
            cardHeight: size.height,
            fold: fold,
            cardGeometry: cardGeometry,
            artworkUpperBound: metrics.artworkUpperBound,
            contentSpacing: metrics.contentSpacing,
            isAccessibilitySize: dynamicTypeSize.isAccessibilitySize,
            titleBlockHeight: contentMeasurements.titleBlockHeight,
            controlsHeight: foldedControlsHeight,
            expandedPaneHeight: paneAllowance
        )
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: metrics.contentSpacing) {
                    artwork(
                        for: episode,
                        size: layout.artworkSize,
                        openContext: NowPlayingSoundLabOpenPanel.CardContext(
                            cardGeometry: cardGeometry,
                            contentWidth: metrics.contentWidth,
                            viewport: CGRect(
                                x: 0,
                                y: layout.mediaViewport.lowerBound,
                                width: size.width,
                                height: layout.mediaViewportHeight
                            )
                        )
                    )
                    titleBlock(for: episode, metrics: metrics)
                }
                .frame(maxWidth: metrics.contentWidth)
                .padding(.leading, metrics.leadingPadding)
                .padding(.trailing, metrics.trailingPadding)
                .padding(.top, layout.mediaTopPadding)
                .padding(.bottom, layout.mediaBottomPadding)
                .frame(maxWidth: .infinity)
            }
            .frame(height: layout.mediaViewportHeight)
            .scrollIndicators(.hidden)
            .scrollPosition($scrollPosition)
            .scrollDisabled(isTrackingDismissDrag)
            .tracksScrolledToTop(area: .media, update: updateScrolledToTop)

            Color.clear
                .frame(height: layout.foldGap)
                .accessibilityHidden(true)

            ScrollView {
                VStack(spacing: metrics.contentSpacing) {
                    progressSection(for: episode)
                    failureBlock
                    transport(containerHeight: size.height)
                    utilityRow(width: metrics.contentWidth)
                    secondaryDisclosure(presentation, paneHeight: paneHeight)
                }
                .onGeometryChange(for: CGFloat.self) { geometry in
                    geometry.size.height - paneAllowance
                } action: { height in
                    updateFoldedControlsHeight(height)
                }
                .frame(maxWidth: metrics.contentWidth)
                .padding(.leading, metrics.leadingPadding)
                .padding(.trailing, metrics.trailingPadding)
                .padding(.top, layout.controlsTopPadding)
                .padding(.bottom, layout.controlsBottomPadding)
                .frame(maxWidth: .infinity)
                .frame(minHeight: layout.controlsViewportHeight, alignment: .top)
                .overlay(alignment: .bottom) {
                    sourcePill(
                        spareHeight: layout.controlsSpareHeight,
                        metrics: metrics,
                        bottomPadding: layout.controlsBottomPadding
                    )
                }
                .animation(
                    accessibilityReduceMotion ? nil : .easeOut(duration: 0.2),
                    value: isPlaybackFailed
                )
            }
            .frame(height: layout.controlsViewportHeight)
            .scrollIndicators(.hidden)
            .scrollPosition($controlsScrollPosition)
            .scrollDisabled(isTrackingDismissDrag)
            .tracksScrolledToTop(area: .controls, update: updateScrolledToTop)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .coordinateSpace(.named(NowPlayingSoundLabOpenPanel.CardContext.coordinateSpaceName))
        .overlay(alignment: .topLeading) {
            moreMenu(geometry: cardGeometry)
        }
        .overlay(alignment: .top) {
            toast(geometry: cardGeometry)
        }
        .animation(
            accessibilityReduceMotion ? .easeOut(duration: 0.2) : .bouncy,
            value: transcriptionRequest?.id
        )
        .animation(
            accessibilityReduceMotion ? .easeOut(duration: 0.2) : .bouncy,
            value: remoteTranscriptionPresentation != nil
        )
    }

    @ViewBuilder
    private func artwork(
        for episode: Episode,
        size: CGFloat,
        openContext: NowPlayingSoundLabOpenPanel.CardContext
    ) -> some View {
        if appModel.replacesNowPlayingArtworkWithPlaybackDiagnostics {
            NowPlayingPlaybackDiagnosticsView(
                text: appModel.playback.playbackDiagnosticsText
                    + appModel.playbackSourceIdentityDiagnostics,
                size: size
            )
        } else {
            NowPlayingSoundLabArtwork(
                title: episode.podcastTitle,
                imageURL: episode.artworkURL?.absoluteString,
                size: size,
                voiceBoostEnabled: $isVoiceBoostEnabled,
                voiceBoostControlEnabled: appModel.playbackSettings.canChangeCurrentEpisodeVoiceBoost,
                onAdFreePassAction: startAdFreePass,
                onTranscribeRemotely: presentRemoteTranscriptionEstimate,
                onTranscriptAction: performTranscriptAction,
                onAdFreePassBackgroundProbe: startAdFreePassBackgroundProbe,
                onRequestSoundLabSheet: presentSoundLabSheet,
                isSoundLabInteractionActive: $isSoundLabInteractionActive,
                isCardDismissDragActive: isTrackingDismissDrag,
                openContext: openContext
            )
        }
    }

    private func titleBlock(for episode: Episode, metrics: NowPlayingContentMetrics) -> some View {
        VStack(spacing: metrics.metadataSpacing) {
            Button(action: openEpisode) {
                Text(episode.title)
                    .font(metrics.titleFont)
                    .multilineTextAlignment(.center)
                    .lineLimit(metrics.titleLineLimit)
                    .minimumScaleFactor(metrics.titleMinimumScaleFactor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.plain)
            .disabled(!canOpenCurrentEpisode)
            .accessibilityHint("Opens the episode description")
            .accessibilityIdentifier("Now Playing Episode Title")

            Button(action: openPodcast) {
                Text(episode.podcastTitle)
                    .font(metrics.podcastFont)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(metrics.podcastLineLimit)
                    .minimumScaleFactor(metrics.podcastMinimumScaleFactor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.plain)
            .disabled(!canOpenCurrentPodcast)
            .accessibilityHint("Opens the show in your library")
            .accessibilityIdentifier("Now Playing Podcast Title")
        }
        .onGeometryChange(for: CGFloat.self) { geometry in
            geometry.size.height
        } action: { height in
            updateMeasurement(\.titleBlockHeight, to: height)
        }
    }

    private func progressSection(for episode: Episode) -> some View {
        ZStack(alignment: .top) {
            NowPlayingProgressSection(episodeID: episode.id.rawValue, onShowChapters: showChapters)
                .padding(.top, accessibilityReduceMotion ? 30 : 0)

            NowPlayingAutoSkipFeedbackView()
                .id(episode.id)
        }
        .padding(.top, 4)
        .onGeometryChange(for: CGFloat.self) { geometry in
            geometry.size.height
        } action: { height in
            updateMeasurement(\.progressSectionHeight, to: height)
        }
    }

    @ViewBuilder
    private var failureBlock: some View {
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
    }

    private func transport(containerHeight: CGFloat) -> some View {
        NowPlayingTransportControls(
            playButtonDiameter: playButtonDiameter,
            skipBackwardInterval: appModel.playbackSettings.skipBackwardOption.seconds,
            skipForwardInterval: appModel.playbackSettings.skipForwardOption.seconds,
            showsPauseButton: showsPauseButton,
            showsLoadingIndicator: appModel.playback.state.showsLoadingIndicator,
            playbackStateText: appModel.playback.state.accessibilityDescription,
            onSkipBackward: skipBackward,
            onTogglePlayPause: togglePlayPause,
            onSkipForward: skipForward
        )
        .padding(.top, transportTopPadding(containerHeight: containerHeight))
        .layoutPriority(2)
    }

    private func utilityRow(width: CGFloat) -> some View {
        NowPlayingUtilityControls(
            rate: appModel.playback.rate,
            availableWidth: width,
            playButtonDiameter: playButtonDiameter,
            onShowSpeed: { utilitySheet = .speed },
            onShowSleepTimer: { utilitySheet = .sleep },
            onShowUpNext: showUpNext,
            onAddNote: addNoteAction
        )
        .padding(.top, utilityTopPadding)
        .layoutPriority(1)
    }

    /// The pane collapsed to its row below the controls, and the same pane
    /// inline in a bounded area once expanded.
    @ViewBuilder
    private func secondaryDisclosure(
        _ presentation: NowPlayingSecondaryPanePresentation,
        paneHeight: CGFloat
    ) -> some View {
        if presentation.style == .disclosure {
            NowPlayingSecondaryDisclosureRow(
                selection: presentation.selection,
                isExpanded: presentation.isExpanded,
                action: toggleSecondaryPane
            )

            if presentation.isExpanded {
                NowPlayingSecondaryPaneView(
                    selection: secondaryPaneSelection,
                    content: presentation.content
                )
                .frame(height: paneHeight)
                .background(.quinary, in: .rect(cornerRadius: 24))
                .clipShape(.rect(cornerRadius: 24))
                .transition(.opacity)
                .reportsSecondaryPaneFrame(slot: .inline, update: updateSecondaryPaneFrame)
            }
        }
    }

    @ViewBuilder
    private func sourcePill(
        spareHeight: CGFloat?,
        metrics: NowPlayingContentMetrics,
        bottomPadding: CGFloat
    ) -> some View {
        if let source = appModel.currentPlaylistSource, showsSourcePill(spareHeight: spareHeight) {
            NowPlayingSourcePill(name: source.name, action: openPlaylist)
                .frame(maxWidth: metrics.contentWidth)
                .padding(.leading, metrics.leadingPadding)
                .padding(.trailing, metrics.trailingPadding)
                .padding(.bottom, bottomPadding)
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private func moreMenu(geometry: NowPlayingCardGeometry) -> some View {
        if appModel.playback.currentEpisode != nil {
            NowPlayingMoreMenu(
                episode: presentedEpisodeSnapshot,
                hasTranscript: hasCompletedTranscript,
                canShowDescription: canOpenCurrentEpisode,
                canShowShow: canOpenCurrentPodcast,
                playlistSourceName: appModel.currentPlaylistSource?.name,
                showsPrivateNotes: appModel.playbackSettings.showsPrivateNoteButtons,
                onTranscriptAction: performTranscriptAction,
                onShowNotes: { utilitySheet = .notes },
                onShowDescription: showDescription,
                onShowShow: openPodcast,
                onShowPlaylist: openPlaylist,
                onAddToPlaylist: addCurrentEpisodeToPlaylist,
                onStopPlayback: stopPlayback
            )
            .padding(.top, geometry.moreOrigin.y)
            .padding(.leading, geometry.moreOrigin.x)
            .opacity(isSoundLabInteractionActive ? 0 : 1)
            .allowsHitTesting(!isSoundLabInteractionActive)
            .animation(.easeOut(duration: 0.15), value: isSoundLabInteractionActive)
        }
    }

    @ViewBuilder
    private func toast(geometry: NowPlayingCardGeometry) -> some View {
        if let remoteTranscriptionPresentation {
            NowPlayingRemoteTranscriptionToast(
                presentation: remoteTranscriptionPresentation,
                canOpenEpisode: canOpenCurrentEpisode,
                onOpenEpisode: openEpisode,
                onResume: resumeRemoteTranscription,
                onCancel: appModel.remoteTranscription.cancel
            )
            .padding(.leading, geometry.toastLeadingPadding)
            .padding(.trailing, geometry.toastTrailingPadding)
            // Its own height, whatever room the top padding leaves, so
            // a move below a region cannot shrink it back above.
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                toastHeight = height
            }
            .padding(.top, geometry.toastTop(height: toastHeight))
            .transition(
                accessibilityReduceMotion
                    ? .opacity
                    : .move(edge: .top).combined(with: .opacity)
            )
        } else if let transcriptionRequest {
            NowPlayingTranscriptionToast(
                request: transcriptionRequest,
                canOpenEpisode: canOpenCurrentEpisode,
                onOpenEpisode: openEpisodeFromTranscriptionToast,
                onDismiss: dismissTranscriptionToast
            )
            .padding(.leading, geometry.toastLeadingPadding)
            .padding(.trailing, geometry.toastTrailingPadding)
            // Its own height, whatever room the top padding leaves, so
            // a move below a region cannot shrink it back above.
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                toastHeight = height
            }
            .padding(.top, geometry.toastTop(height: toastHeight))
            .transition(
                accessibilityReduceMotion
                    ? .opacity
                    : .move(edge: .top).combined(with: .opacity)
            )
        }
    }

    // MARK: The secondary pane

    private var secondaryPane: NowPlayingSecondaryPane {
        NowPlayingSecondaryPane(storedValue: storedSecondaryPane)
    }

    /// The picker's selection, stored as scene state.
    private var secondaryPaneSelection: Binding<NowPlayingSecondaryPane> {
        Binding(
            get: { NowPlayingSecondaryPane(storedValue: storedSecondaryPane) },
            set: { storedSecondaryPane = $0.rawValue }
        )
    }

    private var secondaryPresentation: NowPlayingSecondaryPanePresentation {
        NowPlayingSecondaryPanePresentation(
            arrangement: arrangement,
            selection: secondaryPane,
            isDisclosureExpanded: isSecondaryPaneExpanded,
            presentedSheet: utilitySheet
        )
    }

    private func showUpNext() {
        open(.upNext)
    }

    private func showChapters() {
        open(.chapters)
    }

    private func showDescription() {
        open(.showDescription)
    }

    private func open(_ destination: NowPlayingSecondaryDestination) {
        follow(NowPlayingSecondaryRoute(destination: destination, paneStyle: arrangement.paneStyle))
    }

    private func follow(_ route: NowPlayingSecondaryRoute) {
        switch route {
        case .selectPane(let pane):
            storedSecondaryPane = pane.rawValue
        case .presentSheet(let sheet):
            utilitySheet = sheet
        case .openEpisode:
            openEpisode()
        case .generateTranscript:
            appModel.requestTranscriptForCurrentEpisode(modelContext: modelContext)
        }
    }

    /// The row's expansion grows the stack; under Reduce Motion it appears
    /// without the animation. Expanding scrolls the pane into view.
    private func toggleSecondaryPane() {
        withAnimation(accessibilityReduceMotion ? nil : .easeOut(duration: 0.2)) {
            isSecondaryPaneExpanded.toggle()
            if isSecondaryPaneExpanded {
                if isFoldedLayout {
                    controlsScrollPosition.scrollTo(edge: .bottom)
                } else {
                    scrollPosition.scrollTo(edge: .bottom)
                }
            }
        }
    }

    /// Laptop: the stack split around a horizontal band across the card.
    private var isFoldedLayout: Bool {
        if case .single(let band) = arrangement, band != nil, cardGeometry.horizontalFold != nil {
            true
        } else {
            false
        }
    }

    private func updateSecondaryPaneFrame(_ frame: CGRect?, slot: SecondaryPaneSlot) {
        secondaryPaneFrames[slot] = frame
        dismissDragExcludedFrames = Array(secondaryPaneFrames.values)
    }

    private func updateScrolledToTop(_ isAtTop: Bool, area: ScrollArea) {
        if isAtTop {
            scrolledAwayAreas.remove(area)
        } else {
            scrolledAwayAreas.insert(area)
        }
        isContentScrolledToTop = scrolledAwayAreas.isEmpty
    }

    private func updateFoldedControlsHeight(_ height: CGFloat) {
        if let foldedControlsHeight, abs(foldedControlsHeight - height) <= 1 {
            return
        }
        foldedControlsHeight = height
    }

    /// Nil hides the Now Playing note circle (the Playback setting is off).
    private var addNoteAction: (() -> Void)? {
        guard appModel.playbackSettings.showsPrivateNoteButtons else { return nil }
        return addTimestampedNote
    }

    private func addTimestampedNote() {
        guard let episode = appModel.playback.currentEpisode else { return }
        beginNote(episode: EpisodeListItemSnapshot(episode: episode))
    }

    private func beginNote(episode: EpisodeListItemSnapshot) {
        let session = EpisodeNotePlaybackSession(
            episode: episode,
            timestamp: appModel.playback.position,
            state: appModel.playback.state, pause: appModel.playback.pause,
            playbackIntentRevision: { appModel.playback.playbackIntentRevision }
        )
        notePlaybackSession = session
        noteDraft = session.draft
    }

    private func playNote(at timestamp: TimeInterval, episodeID: String) {
        guard appModel.playback.currentEpisode?.id.rawValue == episodeID else { return }
        appModel.playback.seek(to: timestamp, intent: .scrub)
        appModel.playback.play()
        utilitySheet = nil
    }

    private func resumePlaybackAfterNote() {
        let session = notePlaybackSession
        notePlaybackSession = nil
        session?.finish(
            currentEpisodeID: appModel.playback.currentEpisode?.id.rawValue,
            state: appModel.playback.state,
            playbackIntentRevision: appModel.playback.playbackIntentRevision,
            play: appModel.playback.play
        )
    }

    private var showsPauseButton: Bool {
        appModel.playback.state.showsPauseButton
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
        guard appModel.isNowPlayingPresented, let currentEpisodeID else {
            return false
        }
        return appModel.library.episode(with: currentEpisodeID) != nil
            || appModel.downloads.record(for: currentEpisodeID) != nil
    }

    private var canOpenCurrentPodcast: Bool {
        guard appModel.isNowPlayingPresented, let currentPodcastID else {
            return false
        }
        return appModel.library.isActivelySubscribed(to: currentPodcastID)
    }

    /// The source pill is extra information, so it only takes room the
    /// controls leave free below the utility row. Otherwise, and always at
    /// accessibility sizes and in compact height, the More menu's
    /// "Show <playlist>" item is the route back to the source.
    private func showsSourcePill(spareHeight: CGFloat?) -> Bool {
        guard !dynamicTypeSize.isAccessibilitySize,
              verticalSizeClass != .compact,
              let spareHeight
        else {
            return false
        }
        return spareHeight >= NowPlayingSourcePill.minimumSpareHeight
    }

    /// The first measurement lands while the card is still presenting; later
    /// changes (Dynamic Type, a failure message, another episode's titles)
    /// animate the artwork to the size the fit rule gives it.
    private func updateMeasurement(
        _ keyPath: WritableKeyPath<NowPlayingContentMeasurements, CGFloat?>,
        to height: CGFloat,
        tolerance: CGFloat = 0
    ) {
        let current = contentMeasurements[keyPath: keyPath]
        if let current, abs(current - height) <= tolerance {
            return
        }
        guard current != nil, !accessibilityReduceMotion else {
            contentMeasurements[keyPath: keyPath] = height
            return
        }
        withAnimation(.easeOut(duration: 0.2)) {
            contentMeasurements[keyPath: keyPath] = height
        }
    }

    private var playButtonDiameter: Double {
        NowPlayingTransportControls.resolvedPlayButtonDiameter(
            scaled: playButtonScaledDiameter,
            isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
        )
    }

    /// The first measurement lands while the card is still presenting, so the
    /// pill arrives with it; later changes (Dynamic Type, rotation, a failure
    /// message) fade it in or out.
    private func updateNaturalContentHeight(_ height: CGFloat) {
        guard naturalContentHeight != nil else {
            naturalContentHeight = height
            return
        }
        withAnimation(.easeOut(duration: 0.2)) {
            naturalContentHeight = height
        }
    }

    private var hasCompletedTranscript: Bool {
        guard appModel.isNowPlayingPresented,
              let currentEpisodeID,
              let record = appModel.transcriptions.record(for: currentEpisodeID)
        else {
            return false
        }
        return record.state == .completed && record.transcriptRelativePath != nil
    }

    private var presentedEpisodeSnapshot: EpisodeListItemSnapshot? {
        guard appModel.isNowPlayingPresented, let currentEpisodeID else { return nil }
        return appModel.episodeSnapshot(for: currentEpisodeID)
    }

    /// The Voice Boost error shows over whatever is in front: the Sound Lab
    /// sheet while it is up, the player otherwise.
    private func soundLabError(whileSoundLabSheetShown sheetShown: Bool) -> Binding<String?> {
        Binding(
            get: {
                guard appModel.isNowPlayingPresented, (utilitySheet == .soundLab) == sheetShown else {
                    return nil
                }
                return appModel.playbackSettings.lastErrorMessage
            },
            set: { if $0 == nil { appModel.playbackSettings.clearLastError() } }
        )
    }

    private var transcriptionRequest: EpisodeTranscriptionRequest? {
        guard appModel.isNowPlayingPresented,
              appModel.transcriptionRequests.isPresented,
              let request = appModel.transcriptionRequests.request,
              request.episodeID == currentEpisodeID
        else {
            return nil
        }
        return request
    }

    private var remoteTranscriptionPresentation: RemoteTranscriptionStatusPresentation? {
        guard appModel.isNowPlayingPresented,
              appModel.remoteTranscriptionPurchases.isSurfaceVisible,
              let currentEpisodeID,
              let phase = appModel.remoteTranscription.store.phase(for: currentEpisodeID),
              !phase.isTerminal
        else {
            return nil
        }
        return RemoteTranscriptionStatusPresentation.make(phase: phase)
    }

    /// A completed transcript opens where this arrangement shows it (the
    /// pane beside the player, else its sheet) once its document loads; a
    /// missing one keeps the request flow.
    private func performTranscriptAction() {
        guard let currentEpisodeID else {
            return
        }
        let record = appModel.transcriptions.record(for: currentEpisodeID)
        let relativePath = record?.state == .completed ? record?.transcriptRelativePath : nil
        guard let relativePath else {
            follow(NowPlayingSecondaryRoute.transcriptAction(hasCompletedTranscript: false, paneStyle: livePaneStyle))
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
                // Routed where the arrangement shows it now, not where it
                // was when the load began.
                follow(NowPlayingSecondaryRoute.transcriptAction(
                    hasCompletedTranscript: true,
                    paneStyle: livePaneStyle
                ))
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

    private func openEpisodeFromTranscriptionToast() {
        guard canOpenCurrentEpisode else {
            return
        }
        dismissTranscriptionToast()
        openEpisode()
    }

    private func transportTopPadding(containerHeight: CGFloat) -> CGFloat {
        if dynamicTypeSize.isAccessibilitySize {
            return 8
        }

        return containerHeight > 780 ? 12 : 10
    }

    private var utilityTopPadding: CGFloat {
        if dynamicTypeSize.isAccessibilitySize {
            return 8
        }

        return 6
    }

    private func retryPlayback() {
        appModel.playback.play()
    }

    private func replayFinishedPlayback() {
        appModel.replayFinishedPlayback(modelContext: modelContext)
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

    /// A tap held by the key notice acts only on the episode it was made
    /// for: playback may have moved on while the notice was up.
    private func startAdFreePass() {
        let episodeID = currentEpisodeID
        noticeGate.run(appModel: appModel) {
            guard currentEpisodeID == episodeID else {
                return
            }
            adDetectionModePromptEpisode = appModel.startOrContinueAdFreePassForCurrentEpisodeResolvingMode(
                modelContext: modelContext
            )
        }
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
        switch appModel.confirmRemoteTranscriptionStart(request, modelContext: modelContext) {
        case .started:
            break
        case .unavailable(let message):
            remoteTranscriptionStartErrorMessage = message
        }
    }

    private func resumeRemoteTranscription() {
        switch appModel.resumeRemoteTranscriptionForCurrentEpisode(modelContext: modelContext) {
        case .started:
            break
        case .unavailable(let message):
            remoteTranscriptionStartErrorMessage = message
        }
    }

    private func presentSoundLabSheet() {
        guard appModel.isNowPlayingPresented, utilitySheet == nil else {
            return
        }
        utilitySheet = .soundLab
    }

    private func handOffAdFreePass() {
        handOffFromSoundLabSheet(.adFreePass)
    }

    private func handOffRemoteTranscriptionEstimate() {
        handOffFromSoundLabSheet(.remoteTranscriptionEstimate)
    }

    private func handOffTranscriptAction() {
        handOffFromSoundLabSheet(.transcriptAction)
    }

    /// A Sound Lab sheet action dismisses the sheet first; the flow it opens
    /// starts in `completeSoundLabHandoff` once the sheet is gone, so the
    /// other presenters and the transcript's completion guard see no sheet.
    private func handOffFromSoundLabSheet(_ action: PlayerUtilitySheet.Handoff.Action) {
        soundLabHandoff = PlayerUtilitySheet.Handoff(action: action, episodeID: currentEpisodeID)
        utilitySheet = nil
    }

    private func completeSoundLabHandoff() {
        let handoff = soundLabHandoff
        soundLabHandoff = nil
        switch handoff?.action(
            isNowPlayingPresented: appModel.isNowPlayingPresented,
            presentedSheet: utilitySheet,
            currentEpisodeID: currentEpisodeID
        ) {
        case .adFreePass:
            startAdFreePass()
        case .remoteTranscriptionEstimate:
            presentRemoteTranscriptionEstimate()
        case .transcriptAction:
            performTranscriptAction()
        case nil:
            break
        }
    }

    private func startAdFreePassBackgroundProbe() {
        #if DEBUG
        AdFreePassBackgroundProbe.startFromUserAction()
        #endif
    }

    private func resetPresentation() {
        withTransaction(\.disablesAnimations, true) {
            scrollPosition.scrollTo(edge: .top)
            controlsScrollPosition.scrollTo(edge: .top)
            utilitySheet = nil
            soundLabHandoff = nil
            remoteEstimateRequest = nil
            remoteTranscriptionStartErrorMessage = nil
            adDetectionModePromptEpisode = nil
        }
    }

    private func openEpisode() {
        onOpenEpisode()
    }

    private func openPodcast() {
        onOpenPodcast()
    }

    private func openPlaylist() {
        onOpenPlaylist()
    }

    private func addCurrentEpisodeToPlaylist() {
        guard let currentEpisodeID else {
            return
        }
        appModel.requestAddToPlaylist(episodeID: currentEpisodeID)
    }

    /// The unload, and so the audio stop, lands in the exit animation's
    /// completion. Pausing on the tap held the first frame of the exit for
    /// well over 100 ms, so audio trails the tap by the animation instead.
    private func stopPlayback() {
        onStopPlayback()
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

private extension View {
    /// Reports whether this scroll view rests at its top, and that it does
    /// once it leaves the hierarchy, so the card's dismiss drag starts only
    /// when every visible scroll area is at its top.
    func tracksScrolledToTop(
        area: NowPlayingView.ScrollArea,
        update: @escaping @MainActor (Bool, NowPlayingView.ScrollArea) -> Void
    ) -> some View {
        onScrollGeometryChange(for: Bool.self) { geometry in
            // At rest, a scroll view's top offset is the negative top inset.
            geometry.contentOffset.y <= -geometry.contentInsets.top + 1
        } action: { _, isAtTop in
            update(isAtTop, area)
        }
        .onDisappear {
            update(true, area)
        }
    }

    /// Reports the pane's global frame while it is shown, so a drag that
    /// starts in it scrolls the pane instead of dismissing the card.
    func reportsSecondaryPaneFrame(
        slot: NowPlayingView.SecondaryPaneSlot,
        update: @escaping @MainActor (CGRect?, NowPlayingView.SecondaryPaneSlot) -> Void
    ) -> some View {
        onGeometryChange(for: CGRect.self) { geometry in
            geometry.frame(in: .global)
        } action: { frame in
            update(frame, slot)
        }
        .onDisappear {
            update(nil, slot)
        }
    }
}
