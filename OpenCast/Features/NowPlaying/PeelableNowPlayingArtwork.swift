import SwiftUI

struct PeelableNowPlayingArtwork: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale

    let title: String
    let imageURL: String?
    let size: CGFloat
    @Binding var voiceBoostEnabled: Bool
    let voiceBoostControlEnabled: Bool
    @Binding var isPeelInteractionActive: Bool
    let prewarmsPeelRenderer: Bool
    let prewarmsPeelSettingsPanel: Bool
    let allowsPeelStart: Bool

    @State private var interactionState = NowPlayingPeelInteractionState.closed
    @State private var peelProgress: CGFloat = 0
    @State private var ignoresCurrentDrag = false
    @State private var feedbackTrigger = false
    @State private var touchY: CGFloat = 0.76
    @State private var settleTarget: CGFloat = 0
    @State private var settleVelocity: CGFloat = 0
    @State private var settleRequestID = 0
    @State private var imageState = ArtworkImageState()

    private let cornerRadius: CGFloat = 8

    var body: some View {
        let request = artworkRequest
        let artworkImage = loadedArtworkImage(for: request)

        ZStack {
            if shouldMountSettingsPanel {
                NowPlayingPeelSettingsPanel(
                    revealProgress: peelProgress,
                    voiceBoostEnabled: $voiceBoostEnabled,
                    voiceBoostControlEnabled: voiceBoostControlEnabled
                )
                    .frame(width: size, height: size)
                    .opacity(shouldRenderSettingsPanel ? panelOpacity : 0)
                    .scaleEffect(panelScale, anchor: .trailing)
                    .offset(x: panelOffset)
                    .allowsHitTesting(shouldRenderSettingsPanel && peelProgress > 0.82)
                    .accessibilityHidden(!shouldRenderSettingsPanel || peelProgress < 0.65)
            }

            ZStack {
                if shouldMountPeelRenderer {
                    NowPlayingMetalPeelArtworkView(
                        artworkImage: artworkImage ?? placeholderArtworkImage(),
                        progress: peelProgress,
                        touchY: touchY,
                        isInteracting: isTrackingPeel,
                        settleTarget: settleTarget,
                        settleVelocity: settleVelocity,
                        settleRequestID: settleRequestID,
                        reduceMotion: reduceMotion,
                        onProgressChanged: updateRendererProgress
                    )
                    .opacity(shouldRenderSettingsPanel ? 1 : 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(!shouldRenderSettingsPanel)
                }

                if !shouldRenderSettingsPanel {
                    NowPlayingArtworkImageView(title: title, image: artworkImage)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(.white.opacity(edgeStrokeOpacity), lineWidth: 1)
                .accessibilityHidden(true)
        }
        .overlay(alignment: peelHitAlignment) {
            Color.clear
                .frame(width: peelHitWidth, height: size)
                .contentShape(.rect(cornerRadius: cornerRadius))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Artwork for \(title)")
                .accessibilityValue(isOpen ? "Visual settings shown" : "Visual settings hidden")
                .accessibilityHint(accessibilityHint)
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("Now Playing Artwork")
                .accessibilityAction(named: "Show Visual Settings", showVisualSettings)
                .accessibilityAction(named: "Hide Visual Settings", hideVisualSettings)
                .onTapGesture(perform: toggleVisualSettings)
                .simultaneousGesture(peelGesture)
        }
        .sensoryFeedback(.selection, trigger: feedbackTrigger)
        .task(id: request) {
            _ = await imageState.loadArtwork(for: request, cacheKind: .episode)
        }
    }

    private var isOpen: Bool {
        interactionState.intendedOpen
    }

    private var isTrackingPeel: Bool {
        interactionState.isTrackingDrag
    }

    private var panelOpacity: Double {
        let progress = Double(peelProgress.clamped01)
        return progress * progress * (3 - 2 * progress)
    }

    private var panelScale: CGFloat {
        reduceMotion ? 1 : 0.94 + 0.06 * peelProgress
    }

    private var panelOffset: CGFloat {
        reduceMotion ? size * 0.04 * (1 - peelProgress) : size * 0.03 * (1 - peelProgress)
    }

    private var shouldRenderSettingsPanel: Bool {
        isOpen || isTrackingPeel || peelProgress > 0.001 || settleTarget > 0
    }

    private var canAcceptPeelInput: Bool {
        allowsPeelStart || shouldRenderSettingsPanel
    }

    private var shouldMountSettingsPanel: Bool {
        shouldRenderSettingsPanel || prewarmsPeelSettingsPanel
    }

    private var shouldMountPeelRenderer: Bool {
        shouldRenderSettingsPanel || prewarmsPeelRenderer
    }

    private var accessibilityHint: String {
        if isOpen {
            return "Double-tap to hide visual settings, or drag right to close them."
        }

        return "Double-tap or drag left to reveal visual settings."
    }

    private var edgeStrokeOpacity: Double {
        colorScheme == .dark ? 0.24 : 0.34
    }

    private var revealDistance: CGFloat {
        size * 0.54
    }

    private var peelHitWidth: CGFloat {
        if isOpen, !isTrackingPeel {
            return max(94, size * 0.34)
        }

        return size
    }

    private var peelHitAlignment: Alignment {
        isOpen && !isTrackingPeel ? .leading : .center
    }

    private var peelGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .local)
            .onChanged(updatePeelDrag)
            .onEnded(finishPeelDrag)
    }

    private var artworkURL: URL? {
        guard let imageURL else {
            return nil
        }

        return URL(string: imageURL)
    }

    private var targetPixelSize: CGSize {
        CGSize(width: size * displayScale, height: size * displayScale)
    }

    private var artworkRequest: ArtworkRequest? {
        guard let artworkURL else {
            return nil
        }

        return ArtworkRequest(url: artworkURL, targetPixelSize: targetPixelSize)
    }

    private func updatePeelDrag(_ value: DragGesture.Value) {
        guard !ignoresCurrentDrag else {
            return
        }

        let translation = value.translation
        if !isTrackingPeel {
            guard !NowPlayingDragIntent.shouldPeelYieldToCardDismiss(translation: translation) else {
                ignoresCurrentDrag = true
                return
            }

            guard canAcceptPeelInput else {
                return
            }

            guard let nextState = startingPeelState(with: value) else {
                return
            }

            interactionState = nextState
            isPeelInteractionActive = true
        }

        let baseProgress: CGFloat = isOpen ? 1 : 0
        let verticalAssist = max(0, -translation.height) / (revealDistance * 4)
        let nextProgress = (baseProgress - translation.width / revealDistance + verticalAssist).clamped01
        touchY = peelTouchY(for: value.location.y)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            peelProgress = nextProgress
        }
    }

    private func finishPeelDrag(_ value: DragGesture.Value) {
        defer {
            ignoresCurrentDrag = false
        }

        guard isTrackingPeel else {
            isPeelInteractionActive = false
            return
        }

        let baseProgress: CGFloat = isOpen ? 1 : 0
        let predictedProgress = (baseProgress - value.predictedEndTranslation.width / revealDistance).clamped01
        let initialVelocity = ((predictedProgress - peelProgress) * 9).clamped(to: -7...7)
        let shouldOpen = if isOpen {
            !(peelProgress < 0.52 || predictedProgress < 0.36)
        } else {
            peelProgress > 0.22 || predictedProgress > 0.30
        }

        snap(open: shouldOpen, velocity: initialVelocity)
    }

    private func startingPeelState(with value: DragGesture.Value) -> NowPlayingPeelInteractionState? {
        let translation = value.translation
        let width = translation.width
        let height = translation.height
        let startsNearPeelEdge = value.startLocation.x > size * 0.36
        let horizontalBias = startsNearPeelEdge ? 0.35 : 0.70

        if isOpen, width > 3, abs(width) > abs(height) * 0.45 {
            return .closingDrag
        }

        if width < -3 && abs(width) > abs(height) * horizontalBias {
            return .openingDrag
        }

        return nil
    }

    private func toggleVisualSettings() {
        requestSnap(open: !isOpen)
    }

    private func showVisualSettings() {
        requestSnap(open: true)
    }

    private func hideVisualSettings() {
        requestSnap(open: false)
    }

    private func requestSnap(open: Bool) {
        guard canAcceptPeelInput else {
            return
        }

        Task { @MainActor in
            snap(open: open)
        }
    }

    private func snap(open: Bool, velocity: CGFloat = 0) {
        let target: CGFloat = open ? 1 : 0
        guard isOpen != open || abs(peelProgress - target) > 0.0001 else {
            finishSettlingIfNeeded(progress: target)
            return
        }

        interactionState = .settling(targetOpen: open)
        feedbackTrigger.toggle()
        settleTarget = target
        settleVelocity = reduceMotion ? 0 : velocity

        if reduceMotion {
            withAnimation(.easeOut(duration: 0.18)) {
                peelProgress = target
            }
            interactionState = .settled(open: open)
            isPeelInteractionActive = false
        } else {
            isPeelInteractionActive = open
            settleRequestID += 1
        }
    }

    private func updateRendererProgress(_ progress: CGFloat) {
        let nextProgress = progress.clamped01
        if abs(peelProgress - nextProgress) > 0.0001 {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                peelProgress = nextProgress
            }
        }

        finishSettlingIfNeeded(progress: nextProgress)
    }

    private func finishSettlingIfNeeded(progress: CGFloat) {
        guard let settledState = interactionState.settledIfNeeded(progress: progress) else {
            return
        }

        interactionState = settledState
        isPeelInteractionActive = false
    }

    private func peelTouchY(for locationY: CGFloat) -> CGFloat {
        let rawY = (locationY / size).clamped(to: 0.12...0.92)
        return (rawY * 0.42 + 0.76 * 0.58).clamped(to: 0.18...0.90)
    }

    private func loadedArtworkImage(for request: ArtworkRequest?) -> UIImage? {
        guard let request else {
            return nil
        }

        return imageState.resolvedImage(for: request)
    }

    private func placeholderArtworkImage() -> UIImage {
        return NowPlayingArtworkPlaceholderImageFactory.shared.image(
            title: title,
            size: CGSize(width: size, height: size),
            scale: displayScale
        )
    }
}
