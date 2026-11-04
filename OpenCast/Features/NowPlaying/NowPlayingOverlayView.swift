import SwiftUI

struct NowPlayingOverlayView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @Environment(SceneLibraryLayouts.self) private var sceneLibraryLayouts: SceneLibraryLayouts?

    let onDismissed: () -> Void
    let onOpenEpisode: () -> Void
    let onOpenPodcast: () -> Void
    let onOpenPlaylist: () -> Void
    let onStopPlayback: () -> Void

    @State private var offsetY: CGFloat?
    @State private var isTrackingDismissDrag = false
    @State private var dismissDragLatchBaselineHeight: CGFloat = 0
    @State private var isFinishingDismissal = false
    @State private var isSoundLabInteractionActive = false
    @State private var isContentScrolledToTop = true
    @State private var dismissDragExcludedFrames: [CGRect] = []
    /// Decided on a drag's first change and kept for the whole drag: a drag
    /// that starts in the secondary pane stays the pane's even after the
    /// content beneath it scrolls away. Reset when the drag ends or cancels.
    @GestureState private var dismissDragStartedInPane: Bool?

    private static let accessibilityTitle = "Now Playing"

    private var isPresented: Bool { appModel.isNowPlayingPresented }

    var body: some View {
        // The window's insets, read before the card's reader ignores them; the
        // keyboard's never move the card.
        GeometryReader { safeAreaProxy in
            windowLayer(safeAreaInsets: safeAreaProxy.safeAreaInsets)
        }
        .ignoresSafeArea(.keyboard)
        .allowsHitTesting(isPresented)
    }

    /// The dim and the card in the whole window. The reserved regions are read
    /// here, from the current layout, every time it changes, and the
    /// arrangement is derived from them on every layout.
    private func windowLayer(safeAreaInsets: EdgeInsets) -> some View {
        GeometryReader { proxy in
            let pose = WindowPose(
                horizontalSizeClass: horizontalSizeClass,
                divisionRegions: WindowDivisionRegion.current(in: proxy)
            )
            let arrangement = NowPlayingArrangement(
                pose: pose,
                windowSize: proxy.size,
                isFoldableScene: NowPlayingArrangement.isFoldableScene(
                    latched: sceneLibraryLayouts?.isFoldable ?? false,
                    currentRegions: SceneLibraryLayouts.divisionRegions(in: proxy)
                )
            )
            let surface = NowPlayingSurface(
                windowSize: proxy.size,
                safeAreaInsets: safeAreaInsets,
                pose: pose,
                occlusions: proxy.reservedRegions(kind: .occlusion).filter(\.isActive).map(\.frame),
                isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
            )
            let cardGeometry = arrangement.usesWindowSizedSurface
                ? surface.playerGeometry(allocation: CGRect(origin: .zero, size: proxy.size))
                : NowPlayingCardGeometry(
                    windowSize: proxy.size,
                    safeAreaInsets: safeAreaInsets,
                    isRegular: horizontalSizeClass == .regular,
                    isAccessibilitySize: dynamicTypeSize.isAccessibilitySize,
                    pose: pose,
                    occlusions: surface.occlusions
                )
            // A foldable scene's surface is the window; the player's own
            // allocation inside it comes from the arrangement.
            let surfaceFrame = arrangement.usesWindowSizedSurface
                ? CGRect(origin: .zero, size: proxy.size)
                : cardGeometry.cardFrame
            let currentOffset = resolvedOffset(in: proxy)
            let progress = presentationProgress(offset: currentOffset, in: proxy)
            let cornerRadius = cornerRadius(progress: progress, isWindowSized: arrangement.usesWindowSizedSurface)
            let cardShape = RoundedRectangle(cornerRadius: cornerRadius)

            ZStack(alignment: .bottom) {
                Color.black
                    .opacity(dimOpacity(progress: progress))
                    .ignoresSafeArea()
                    .accessibilityHidden(true)

                NowPlayingView(
                    cardGeometry: cardGeometry,
                    arrangement: arrangement,
                    surface: surface,
                    isSoundLabInteractionActive: $isSoundLabInteractionActive,
                    isContentScrolledToTop: $isContentScrolledToTop,
                    dismissDragExcludedFrames: $dismissDragExcludedFrames,
                    isTrackingDismissDrag: isTrackingDismissDrag,
                    onDismiss: { dismiss(containerHeight: proxy.size.height) },
                    onOpenEpisode: { openEpisode(containerHeight: proxy.size.height) },
                    onOpenPodcast: { openPodcast(containerHeight: proxy.size.height) },
                    onOpenPlaylist: { openPlaylist(containerHeight: proxy.size.height) },
                    onStopPlayback: { stopPlayback(containerHeight: proxy.size.height) }
                )
                .frame(width: surfaceFrame.width, height: surfaceFrame.height)
                .background(playerSurface)
                .clipShape(cardShape)
                .overlay {
                    cardShape
                        .stroke(cardStrokeColor(progress: progress), lineWidth: 1)
                }
                .contentShape(.rect)
                .simultaneousGesture(
                    dismissDragGesture(
                        dismissDistance: dismissDistance(in: proxy),
                        containerHeight: proxy.size.height
                    )
                )
                .shadow(color: .black.opacity(shadowOpacity(progress: progress)), radius: 30, y: -8)
                .scaleEffect(cardScale(progress: progress), anchor: .bottom)
                .offset(y: currentOffset)
                .accessibilityElement(children: .contain)
                // XCTest can still resolve a retained container while it is hidden.
                .accessibilityLabel(isPresented ? Text(Self.accessibilityTitle) : Text(""))
                .accessibilityIdentifier(isPresented ? Self.accessibilityTitle : "")
                .accessibilityHidden(!isPresented)
                .padding(.leading, surfaceFrame.minX)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                nowPlayingProbeMark(isPresented ? "overlay-mounted" : "overlay-prepared")
                updatePresentation(isPresented: isPresented, containerHeight: proxy.size.height)
            }
            .onChange(of: isPresented) { _, newValue in
                if newValue { nowPlayingProbeMark("overlay-reused") }
                updatePresentation(isPresented: newValue, containerHeight: proxy.size.height)
            }
            .onChange(of: proxy.size.height) { _, height in
                if !isPresented { prepareForHiddenPresentation(containerHeight: height) }
            }
            .onChange(of: reduceMotion) { _, _ in
                if !isPresented { prepareForHiddenPresentation(containerHeight: proxy.size.height) }
            }
            .onChange(of: appModel.playback.currentEpisode?.id.rawValue) { _, _ in
                if !isPresented { prepareForHiddenPresentation(containerHeight: proxy.size.height) }
            }
            .onChange(of: scenePhase) { _, newPhase in
                handleScenePhaseChange(newPhase)
            }
            .opacity(isPresented ? 1 : 0)
        }
        .ignoresSafeArea()
    }

    private var playerSurface: Color {
        Color(.systemBackground)
    }

    private func resolvedOffset(in proxy: GeometryProxy) -> CGFloat {
        guard let offsetY else {
            return reduceMotion ? 0 : proxy.size.height
        }

        return max(offsetY, 0)
    }

    private func presentationProgress(offset: CGFloat, in proxy: GeometryProxy) -> CGFloat {
        guard !reduceMotion else {
            return 1
        }

        return (1 - offset / dismissDistance(in: proxy)).clamped01
    }

    private func dismissDistance(in proxy: GeometryProxy) -> CGFloat {
        (proxy.size.height * 0.46).clamped(to: 300...540)
    }

    private func dimOpacity(progress: CGFloat) -> Double {
        Double(progress) * (colorScheme == .dark ? 0.56 : 0.24)
    }

    private func cardScale(progress: CGFloat) -> CGFloat {
        guard !reduceMotion else {
            return 1
        }

        let collapsedScale: CGFloat = horizontalSizeClass == .regular ? 0.94 : 0.80
        return collapsedScale + (1 - collapsedScale) * progress
    }

    /// A window-sized surface rounds only while it moves, like the compact
    /// card, with the regular card's radius.
    private func cornerRadius(progress: CGFloat, isWindowSized: Bool) -> CGFloat {
        if isWindowSized {
            return (1 - progress) * 36
        }

        if horizontalSizeClass == .regular {
            return 36
        }

        return (1 - progress) * 46
    }

    private func shadowOpacity(progress: CGFloat) -> Double {
        Double(1 - progress) * (colorScheme == .dark ? 0.34 : 0.18)
    }

    private func cardStrokeColor(progress: CGFloat) -> Color {
        colorScheme == .dark
            ? .white.opacity(Double(1 - progress) * 0.14)
            : .black.opacity(0.08 + Double(1 - progress) * 0.08)
    }

    private func prepareForPresentation(containerHeight: CGFloat) {
        if reduceMotion {
            offsetY = 0
            nowPlayingProbeMark("card-settled")
            return
        }

        // Re-entry while already presented should not replay the card spring.
        guard offsetY != 0 else {
            return
        }

        if offsetY == nil {
            offsetY = containerHeight
        }

        nowPlayingProbeMark("card-animate-start")
        withAnimation(springAnimation(response: 0.34, damping: 0.88)) {
            offsetY = 0
        } completion: {
            nowPlayingProbeMark("card-settled")
        }
    }

    private func prepareForHiddenPresentation(containerHeight: CGFloat) {
        withTransaction(\.disablesAnimations, true) {
            offsetY = reduceMotion ? 0 : containerHeight
            resetOverlayInteractionState()
        }
    }

    private func updatePresentation(isPresented: Bool, containerHeight: CGFloat) {
        if isPresented {
            prepareForPresentation(containerHeight: containerHeight)
        } else {
            prepareForHiddenPresentation(containerHeight: containerHeight)
        }
    }

    private func resetNonDismissInteractionState() {
        isSoundLabInteractionActive = false
        isContentScrolledToTop = true
    }

    private func resetOverlayInteractionState() {
        isTrackingDismissDrag = false
        dismissDragLatchBaselineHeight = 0
        isFinishingDismissal = false
        resetNonDismissInteractionState()
    }

    private func handleScenePhaseChange(_ newPhase: ScenePhase) {
        switch newPhase {
        case .inactive, .background:
            nowPlayingProbeMark("scene-exit")
            resetOverlayInteractionState()
        case .active:
            nowPlayingProbeMark("scene-active")
        @unknown default:
            break
        }
    }

    private func dismiss(containerHeight: CGFloat) {
        dismiss(containerHeight: containerHeight, completion: nil)
    }

    private func openEpisode(containerHeight: CGFloat) {
        dismiss(containerHeight: containerHeight, completion: onOpenEpisode)
    }

    private func openPodcast(containerHeight: CGFloat) {
        dismiss(containerHeight: containerHeight, completion: onOpenPodcast)
    }

    private func openPlaylist(containerHeight: CGFloat) {
        dismiss(containerHeight: containerHeight, completion: onOpenPlaylist)
    }

    private func stopPlayback(containerHeight: CGFloat) {
        dismiss(containerHeight: containerHeight, completion: onStopPlayback)
    }

    private func dismiss(containerHeight: CGFloat, completion: (() -> Void)?) {
        guard !isFinishingDismissal else {
            return
        }

        nowPlayingProbeMark("dismiss-animate-start")
        if reduceMotion {
            onDismissed()
            completion?()
            return
        }

        isFinishingDismissal = true
        isTrackingDismissDrag = false
        dismissDragLatchBaselineHeight = 0
        withAnimation(springAnimation(response: 0.24, damping: 0.92)) {
            offsetY = containerHeight
        } completion: {
            nowPlayingProbeMark("card-dismissed")
            onDismissed()
            completion?()
        }
    }

    private func updateDismissDrag(_ value: DragGesture.Value) {
        guard !isFinishingDismissal else {
            return
        }

        if !isTrackingDismissDrag {
            let startedInPane = dismissDragStartedInPane
                ?? NowPlayingDragIntent.startsInSecondaryPane(value.startLocation, paneFrames: dismissDragExcludedFrames)
            guard !startedInPane else {
                return
            }

            guard isContentScrolledToTop else {
                return
            }

            guard NowPlayingDragIntent.shouldStartCardDismiss(
                translation: value.translation,
                isSoundLabInteractionActive: isSoundLabInteractionActive
            ) else {
                return
            }

            nowPlayingProbeMark("dismiss-drag-start")
            isTrackingDismissDrag = true
            dismissDragLatchBaselineHeight = value.translation.height
        }

        withTransaction(\.disablesAnimations, true) {
            offsetY = reduceMotion ? 0 : max(value.translation.height - dismissDragLatchBaselineHeight, 0)
        }
    }

    private func dismissDragGesture(
        dismissDistance: CGFloat,
        containerHeight: CGFloat
    ) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .updating($dismissDragStartedInPane) { value, startedInPane, _ in
                if startedInPane == nil {
                    startedInPane = NowPlayingDragIntent.startsInSecondaryPane(
                        value.startLocation,
                        paneFrames: dismissDragExcludedFrames
                    )
                }
            }
            .onChanged(updateDismissDrag)
            .onEnded {
                finishDismissDrag(
                    $0,
                    dismissDistance: dismissDistance,
                    containerHeight: containerHeight
                )
            }
    }

    private func finishDismissDrag(
        _ value: DragGesture.Value,
        dismissDistance: CGFloat,
        containerHeight: CGFloat
    ) {
        guard isTrackingDismissDrag else {
            return
        }

        let latchBaselineHeight = dismissDragLatchBaselineHeight
        let translation = max(value.translation.height - latchBaselineHeight, 0)
        let predictedTranslation = max(value.predictedEndTranslation.height - latchBaselineHeight, translation)
        let shouldDismiss = translation > dismissDistance * 0.28
            || predictedTranslation > dismissDistance * 0.56

        nowPlayingProbeMark("dismiss-drag-ended")
        isTrackingDismissDrag = false
        dismissDragLatchBaselineHeight = 0
        if shouldDismiss {
            dismiss(containerHeight: containerHeight)
        } else {
            guard !reduceMotion else {
                return
            }

            withAnimation(springAnimation(response: 0.24, damping: 0.88)) {
                offsetY = 0
            }
        }
    }

    private func springAnimation(response: Double, damping: Double) -> Animation {
        .interactiveSpring(response: response, dampingFraction: damping)
    }
}
