import SwiftUI

struct NowPlayingOverlayView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase

    let isPresented: Bool
    let onDismissed: () -> Void
    let onOpenEpisode: () -> Void
    let onOpenPodcast: () -> Void

    @State private var offsetY: CGFloat?
    @State private var isTrackingDismissDrag = false
    @State private var dismissDragLatchBaselineHeight: CGFloat = 0
    @State private var isFinishingDismissal = false
    @State private var isPeelInteractionActive = false
    @State private var isContentScrolledToTop = true
    @State private var prewarmsPeelRenderer = false
    @State private var prewarmsPeelSettingsPanel = false
    @State private var peelPrewarmRequestID = 0
    @State private var suppressesColdPeelStart = false
    @State private var peelRendererPrewarmTask: Task<Void, Never>?
    @State private var peelSettingsPanelPrewarmTask: Task<Void, Never>?

    private static let accessibilityTitle = "Now Playing"
    private static let peelPrewarmIdleDelay: TimeInterval = 0.6
    private static let postForegroundPeelPrewarmDelay: TimeInterval = 1.25

    var body: some View {
        GeometryReader { proxy in
            let cardSize = cardSize(in: proxy)
            let currentOffset = resolvedOffset(in: proxy)
            let progress = presentationProgress(offset: currentOffset, in: proxy)
            let cornerRadius = cornerRadius(progress: progress)
            let cardShape = RoundedRectangle(cornerRadius: cornerRadius)

            ZStack(alignment: .bottom) {
                Color.black
                    .opacity(dimOpacity(progress: progress))
                    .ignoresSafeArea()
                    .accessibilityHidden(true)

                NowPlayingView(
                    bottomContentPadding: proxy.safeAreaInsets.bottom + bottomContentPadding,
                    topContentPadding: topContentPadding(in: proxy),
                    isPeelInteractionActive: $isPeelInteractionActive,
                    isContentScrolledToTop: $isContentScrolledToTop,
                    isTrackingDismissDrag: isTrackingDismissDrag,
                    prewarmsPeelRenderer: prewarmsPeelRenderer,
                    prewarmsPeelSettingsPanel: prewarmsPeelSettingsPanel,
                    allowsPeelStart: !suppressesColdPeelStart,
                    onDismiss: { dismiss(containerHeight: proxy.size.height) },
                    onOpenEpisode: { openEpisode(containerHeight: proxy.size.height) },
                    onOpenPodcast: { openPodcast(containerHeight: proxy.size.height) }
                )
                .frame(width: cardSize.width, height: cardSize.height)
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
                .accessibilityLabel(isPresented ? Text(Self.accessibilityTitle) : Text(""))
                .accessibilityIdentifier(isPresented ? Self.accessibilityTitle : "")
                .accessibilityHidden(!isPresented)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                nowPlayingProbeMark("overlay-mounted")
                updatePresentation(isPresented: isPresented, containerHeight: proxy.size.height)
            }
            .onChange(of: isPresented) { _, newValue in
                updatePresentation(isPresented: newValue, containerHeight: proxy.size.height)
            }
            .onChange(of: appModel.playback.currentEpisode?.id.rawValue) { _, _ in
                resetPresentedEpisode(isPresented: isPresented, containerHeight: proxy.size.height)
            }
            .onChange(of: scenePhase) { _, newPhase in
                handleScenePhaseChange(newPhase, isPresented: isPresented)
            }
            .opacity(isPresented ? 1 : 0)
        }
        .ignoresSafeArea()
    }

    private var playerSurface: Color {
        Color(.systemBackground)
    }

    private var bottomContentPadding: CGFloat {
        horizontalSizeClass == .regular ? 32 : 22
    }

    private func cardSize(in proxy: GeometryProxy) -> CGSize {
        if horizontalSizeClass == .regular {
            return CGSize(
                width: (proxy.size.width - 80).clamped(to: 0...660),
                height: (proxy.size.height - 72).clamped(to: 0...860)
            )
        }

        return proxy.size
    }

    private func resolvedOffset(in proxy: GeometryProxy) -> CGFloat {
        guard let offsetY else {
            return reduceMotion ? 0 : proxy.size.height
        }

        return max(offsetY, 0)
    }

    private func topContentPadding(in proxy: GeometryProxy) -> CGFloat {
        if horizontalSizeClass == .regular {
            return dynamicTypeSize.isAccessibilitySize ? 56 : 96
        }

        if dynamicTypeSize.isAccessibilitySize {
            return proxy.safeAreaInsets.top + (proxy.size.height < 700 ? 14 : 28)
        }

        return proxy.safeAreaInsets.top + (proxy.size.height < 720 ? 92 : 150)
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

    private func cornerRadius(progress: CGFloat) -> CGFloat {
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
        let prewarmRequestID = resetPeelRendererPrewarm()
        suppressesColdPeelStart = false

        if reduceMotion {
            offsetY = 0
            schedulePeelRendererPrewarm(requestID: prewarmRequestID)
            return
        }

        // Re-entry while already presented should not replay the card spring.
        guard offsetY != 0 else {
            schedulePeelRendererPrewarm(requestID: prewarmRequestID)
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
            schedulePeelRendererPrewarm(requestID: prewarmRequestID)
        }
    }

    private func prepareForHiddenPrewarm(containerHeight: CGFloat) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            offsetY = reduceMotion ? 0 : containerHeight
            resetPeelRendererPrewarm()
            suppressesColdPeelStart = false
            resetOverlayInteractionState()
        }
    }

    private func updatePresentation(isPresented: Bool, containerHeight: CGFloat) {
        if isPresented {
            prepareForPresentation(containerHeight: containerHeight)
        } else {
            prepareForHiddenPrewarm(containerHeight: containerHeight)
        }
    }

    private func resetPresentedEpisode(isPresented: Bool, containerHeight: CGFloat) {
        let prewarmRequestID = resetPeelRendererPrewarm()
        let shouldKeepPresentedOffset = isPresented && offsetY == 0
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            offsetY = reduceMotion || shouldKeepPresentedOffset ? 0 : containerHeight
            suppressesColdPeelStart = false
            resetOverlayInteractionState()
        }
        if isPresented {
            schedulePeelRendererPrewarm(requestID: prewarmRequestID)
        }
    }

    private func resetOverlayInteractionState() {
        isTrackingDismissDrag = false
        dismissDragLatchBaselineHeight = 0
        isFinishingDismissal = false
        isPeelInteractionActive = false
        isContentScrolledToTop = true
    }

    @discardableResult
    private func resetPeelRendererPrewarm() -> Int {
        cancelPeelPrewarmTasks()
        peelPrewarmRequestID += 1
        prewarmsPeelRenderer = false
        prewarmsPeelSettingsPanel = false
        return peelPrewarmRequestID
    }

    private func cancelPeelPrewarmTasks() {
        peelRendererPrewarmTask?.cancel()
        peelRendererPrewarmTask = nil
        peelSettingsPanelPrewarmTask?.cancel()
        peelSettingsPanelPrewarmTask = nil
    }

    private func cancelPendingPeelPrewarmForDismissDrag() {
        cancelPeelPrewarmTasks()
        peelPrewarmRequestID += 1
        if !prewarmsPeelRenderer {
            prewarmsPeelSettingsPanel = false
        }
    }

    private func schedulePeelRendererPrewarm(
        requestID: Int,
        delay: TimeInterval = Self.peelPrewarmIdleDelay
    ) {
        peelRendererPrewarmTask?.cancel()
        nowPlayingProbeMark("peel-prewarm-scheduled")
        peelRendererPrewarmTask = Task {
            // Defer the Metal peel mount (~75ms shader + drawable-surface setup) to a
            // quiet window after the entrance spring settles. Mounting it inside the
            // presentation animation drops frames; on the static, settled card the
            // one-time main-thread cost is imperceptible.
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch is CancellationError {
                return
            } catch {
                return
            }
            finishPeelRendererPrewarm(requestID: requestID)
        }
    }

    private func finishPeelRendererPrewarm(requestID: Int) {
        guard requestID == peelPrewarmRequestID, offsetY == 0 else {
            return
        }

        prewarmsPeelRenderer = true
        suppressesColdPeelStart = false
        nowPlayingProbeMark("peel-prewarm-finished")
        schedulePeelSettingsPanelPrewarm(requestID: requestID)
    }

    private func schedulePeelSettingsPanelPrewarm(requestID: Int) {
        peelSettingsPanelPrewarmTask?.cancel()
        peelSettingsPanelPrewarmTask = Task {
            do {
                try await Task.sleep(for: .seconds(1))
            } catch is CancellationError {
                return
            } catch {
                return
            }
            finishPeelSettingsPanelPrewarm(requestID: requestID)
        }
    }

    private func finishPeelSettingsPanelPrewarm(requestID: Int) {
        guard requestID == peelPrewarmRequestID, offsetY == 0 else {
            return
        }

        prewarmsPeelSettingsPanel = true
    }

    private func handleScenePhaseChange(_ newPhase: ScenePhase, isPresented: Bool) {
        switch newPhase {
        case .inactive, .background:
            nowPlayingProbeMark("scene-exit")
            suppressesColdPeelStart = true
            resetPeelRendererPrewarm()
            resetOverlayInteractionState()
        case .active:
            nowPlayingProbeMark("scene-active")
            guard isPresented else {
                suppressesColdPeelStart = false
                return
            }

            let prewarmRequestID = resetPeelRendererPrewarm()
            suppressesColdPeelStart = true
            schedulePeelRendererPrewarm(
                requestID: prewarmRequestID,
                delay: Self.postForegroundPeelPrewarmDelay
            )
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

    private func dismiss(containerHeight: CGFloat, completion: (() -> Void)?) {
        guard !isFinishingDismissal else {
            return
        }

        if reduceMotion {
            resetPeelRendererPrewarm()
            onDismissed()
            completion?()
            return
        }

        resetPeelRendererPrewarm()
        isFinishingDismissal = true
        isTrackingDismissDrag = false
        dismissDragLatchBaselineHeight = 0
        withAnimation(springAnimation(response: 0.24, damping: 0.92)) {
            offsetY = containerHeight
        } completion: {
            onDismissed()
            completion?()
        }
    }

    private func updateDismissDrag(_ value: DragGesture.Value) {
        guard !isFinishingDismissal else {
            return
        }

        if !isTrackingDismissDrag {
            guard isContentScrolledToTop else {
                return
            }

            guard NowPlayingDragIntent.shouldStartCardDismiss(
                translation: value.translation,
                isPeelInteractionActive: isPeelInteractionActive
            ) else {
                return
            }

            nowPlayingProbeMark("dismiss-drag-start")
            cancelPendingPeelPrewarmForDismissDrag()
            isTrackingDismissDrag = true
            dismissDragLatchBaselineHeight = value.translation.height
        }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            offsetY = reduceMotion ? 0 : max(value.translation.height - dismissDragLatchBaselineHeight, 0)
        }
    }

    private func dismissDragGesture(
        dismissDistance: CGFloat,
        containerHeight: CGFloat
    ) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
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

        isTrackingDismissDrag = false
        dismissDragLatchBaselineHeight = 0
        if shouldDismiss {
            dismiss(containerHeight: containerHeight)
        } else {
            let prewarmRequestID = peelPrewarmRequestID
            guard !reduceMotion else {
                if !prewarmsPeelRenderer {
                    schedulePeelRendererPrewarm(requestID: prewarmRequestID)
                }
                return
            }

            withAnimation(springAnimation(response: 0.24, damping: 0.88)) {
                offsetY = 0
            } completion: {
                if !prewarmsPeelRenderer {
                    schedulePeelRendererPrewarm(requestID: prewarmRequestID)
                }
            }
        }
    }

    private func springAnimation(response: Double, damping: Double) -> Animation {
        .interactiveSpring(response: response, dampingFraction: damping)
    }
}
