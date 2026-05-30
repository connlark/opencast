import SwiftUI

struct NowPlayingOverlayView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let isPresented: Bool
    let onDismissed: () -> Void
    let onOpenEpisode: () -> Void
    let onOpenPodcast: () -> Void

    @State private var offsetY: CGFloat?
    @State private var isTrackingDismissDrag = false
    @State private var isFinishingDismissal = false
    @State private var isPeelInteractionActive = false
    @State private var prewarmsPeelRenderer = false
    @State private var prewarmsPeelSettingsPanel = false
    @State private var peelPrewarmRequestID = 0

    private static let accessibilityTitle = "Now Playing"
    private static let peelPrewarmIdleDelay: TimeInterval = 0.6

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
                    prewarmsPeelRenderer: prewarmsPeelRenderer,
                    prewarmsPeelSettingsPanel: prewarmsPeelSettingsPanel,
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
                updatePresentation(isPresented: isPresented, containerHeight: proxy.size.height)
            }
            .onChange(of: isPresented) { _, newValue in
                updatePresentation(isPresented: newValue, containerHeight: proxy.size.height)
            }
            .onChange(of: appModel.playback.currentEpisode?.id.rawValue) { _, _ in
                resetPresentedEpisode(isPresented: isPresented, containerHeight: proxy.size.height)
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
            return 96
        }

        return proxy.safeAreaInsets.top + 150
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
            resetOverlayInteractionState()
        }
        if isPresented {
            schedulePeelRendererPrewarm(requestID: prewarmRequestID)
        }
    }

    private func resetOverlayInteractionState() {
        isTrackingDismissDrag = false
        isFinishingDismissal = false
        isPeelInteractionActive = false
    }

    @discardableResult
    private func resetPeelRendererPrewarm() -> Int {
        peelPrewarmRequestID += 1
        prewarmsPeelRenderer = false
        prewarmsPeelSettingsPanel = false
        return peelPrewarmRequestID
    }

    private func schedulePeelRendererPrewarm(requestID: Int) {
        Task {
            // Defer the Metal peel mount (~75ms shader + drawable-surface setup) to a
            // quiet window after the entrance spring settles. Mounting it inside the
            // presentation animation drops frames; on the static, settled card the
            // one-time main-thread cost is imperceptible.
            try? await Task.sleep(for: .seconds(Self.peelPrewarmIdleDelay))
            finishPeelRendererPrewarm(requestID: requestID)
        }
    }

    private func finishPeelRendererPrewarm(requestID: Int) {
        guard requestID == peelPrewarmRequestID, offsetY == 0 else {
            return
        }

        prewarmsPeelRenderer = true
        schedulePeelSettingsPanelPrewarm(requestID: requestID)
    }

    private func schedulePeelSettingsPanelPrewarm(requestID: Int) {
        Task {
            try? await Task.sleep(for: .seconds(1))
            finishPeelSettingsPanelPrewarm(requestID: requestID)
        }
    }

    private func finishPeelSettingsPanelPrewarm(requestID: Int) {
        guard requestID == peelPrewarmRequestID, offsetY == 0 else {
            return
        }

        prewarmsPeelSettingsPanel = true
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
        withAnimation(springAnimation(response: 0.24, damping: 0.92)) {
            offsetY = containerHeight
        } completion: {
            onDismissed()
            completion?()
        }
    }

    private func updateDismissDrag(_ value: DragGesture.Value) {
        guard !isFinishingDismissal, !reduceMotion else {
            return
        }

        if !isTrackingDismissDrag {
            guard NowPlayingDragIntent.shouldStartCardDismiss(
                translation: value.translation,
                isPeelInteractionActive: isPeelInteractionActive
            ) else {
                return
            }

            isTrackingDismissDrag = true
        }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            offsetY = max(value.translation.height, 0)
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

        let translation = max(value.translation.height, 0)
        let predictedTranslation = max(value.predictedEndTranslation.height, translation)
        let shouldDismiss = translation > dismissDistance * 0.28
            || predictedTranslation > dismissDistance * 0.56

        isTrackingDismissDrag = false
        if shouldDismiss {
            dismiss(containerHeight: containerHeight)
        } else {
            withAnimation(springAnimation(response: 0.24, damping: 0.88)) {
                offsetY = 0
            }
        }
    }

    private func springAnimation(response: Double, damping: Double) -> Animation {
        .interactiveSpring(response: response, dampingFraction: damping)
    }
}
