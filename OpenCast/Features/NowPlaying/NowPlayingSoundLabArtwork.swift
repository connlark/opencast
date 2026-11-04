import SwiftUI

struct NowPlayingSoundLabArtwork: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.appStoreSoundLabRevealProgress) private var pinnedRevealProgress

    let title: String
    let imageURL: String?
    let size: CGFloat
    @Binding var voiceBoostEnabled: Bool
    let voiceBoostControlEnabled: Bool
    let onAdFreePassAction: () -> Void
    let onTranscribeRemotely: () -> Void
    let onTranscriptAction: () -> Void
    let onAdFreePassBackgroundProbe: () -> Void
    /// Below the panel's inline floor the reveal asks the player for the
    /// Sound Lab sheet instead.
    let onRequestSoundLabSheet: () -> Void
    @Binding var isSoundLabInteractionActive: Bool
    let isCardDismissDragActive: Bool

    @State private var interactionState = NowPlayingSoundLabInteractionState.closed
    @State private var revealProgress: CGFloat = 0
    @State private var ignoresCurrentDrag = false
    @State private var feedbackTrigger = false
    @State private var imageState = ArtworkImageState()

    private let cornerRadius: CGFloat = 8
    /// A release opens the panel past this much of the reveal, or past
    /// `openingPredictedProgress` of it by the drag's predicted end.
    private static let openingProgress: CGFloat = 0.22
    private static let openingPredictedProgress: CGFloat = 0.30

    var body: some View {
        let request = artworkRequest
        let loadingRequest = appModel.isNowPlayingPresented ? request : nil
        let artworkImage = loadedArtworkImage(for: request)

        ZStack {
            if shouldRenderSoundLabPanel {
                NowPlayingSoundLabPanelHost(
                    presentation: .inline(revealProgress: revealProgress),
                    voiceBoostEnabled: $voiceBoostEnabled,
                    voiceBoostControlEnabled: voiceBoostControlEnabled,
                    onAdFreePassAction: onAdFreePassAction,
                    onTranscribeRemotely: onTranscribeRemotely,
                    onTranscriptAction: onTranscriptAction,
                    onAdFreePassBackgroundProbe: onAdFreePassBackgroundProbe
                )
                .frame(width: size, height: size)
                .opacity(panelOpacity)
                .scaleEffect(panelScale, anchor: .trailing)
                .offset(x: panelOffset)
                .allowsHitTesting(revealProgress > 0.82)
                .accessibilityHidden(revealProgress < 0.65)
            }

            NowPlayingArtworkImageView(title: title, image: artworkImage)
                .opacity(1 - 0.10 * Double(revealProgress))
                .offset(x: -(size - panelLayout.artworkExposedWidth) * revealProgress)
                .allowsHitTesting(false)
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(.white.opacity(edgeStrokeOpacity), lineWidth: 1)
                .accessibilityHidden(true)
        }
        .overlay(alignment: .leading) {
            Color.clear
                .frame(width: soundLabHitSpan.upperBound - soundLabHitSpan.lowerBound, height: size)
                .contentShape(.rect(cornerRadius: cornerRadius))
                .offset(x: soundLabHitSpan.lowerBound)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Artwork for \(title)")
                .accessibilityValue(isOpen ? "Visual settings shown" : "Visual settings hidden")
                .accessibilityHint(accessibilityHint)
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("Now Playing Artwork")
                .accessibilityAction(named: "Show Visual Settings", showVisualSettings)
                .accessibilityAction(named: "Hide Visual Settings", hideVisualSettings)
                .onTapGesture(perform: toggleVisualSettings)
                .simultaneousGesture(soundLabGesture)
        }
        .sensoryFeedback(.selection, trigger: feedbackTrigger)
        .onAppear(perform: applyPinnedReveal)
        .onChange(of: appModel.isNowPlayingPresented) { _, isPresented in
            if !isPresented { resetInteraction() }
        }
        .onChange(of: showsInlinePanel) { _, showsInline in
            if !showsInline { resetInteraction() }
        }
        .task(id: loadingRequest) {
            // Dismissal pauses loading without dropping the displayed bitmap.
            // Reopening can render it even after the shared cache evicts it.
            guard let loadingRequest else { return }
            _ = await imageState.loadArtwork(for: loadingRequest, cacheKind: .episode)
        }
    }

    private func resetInteraction() {
        withTransaction(\.disablesAnimations, true) {
            interactionState = .closed
            revealProgress = 0
            ignoresCurrentDrag = false
            isSoundLabInteractionActive = false
            applyPinnedReveal()
        }
    }

    private func applyPinnedReveal() {
        guard let pinnedRevealProgress, showsInlinePanel else {
            return
        }

        revealProgress = CGFloat(pinnedRevealProgress).clamped01
        interactionState = .open
    }

    private var isOpen: Bool {
        interactionState.intendedOpen
    }

    private var isTrackingSoundLab: Bool {
        interactionState.isTrackingDrag
    }

    private var panelOpacity: Double {
        let progress = Double(revealProgress.clamped01)
        return progress * progress * (3 - 2 * progress)
    }

    private var panelScale: CGFloat {
        reduceMotion ? 1 : 0.94 + 0.06 * revealProgress
    }

    private var panelOffset: CGFloat {
        reduceMotion ? size * 0.04 * (1 - revealProgress) : size * 0.03 * (1 - revealProgress)
    }

    private var showsInlinePanel: Bool {
        NowPlayingSoundLabLayout.showsInline(panelSide: size)
    }

    private var shouldRenderSoundLabPanel: Bool {
        guard showsInlinePanel else {
            return false
        }
        return switch interactionState {
        case .closed:
            revealProgress > 0.001
        case .openingDrag, .open, .closingDrag, .settling:
            true
        }
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

    private var panelLayout: NowPlayingSoundLabLayout {
        NowPlayingSoundLabLayout(panelWidth: size)
    }

    private var soundLabHitSpan: ClosedRange<CGFloat> {
        panelLayout.artworkHitSpan(panelSide: size, isSettledOpen: isOpen && !isTrackingSoundLab)
    }

    private var soundLabGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .local)
            .onChanged(updateSoundLabDrag)
            .onEnded(finishSoundLabDrag)
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

    private func updateSoundLabDrag(_ value: DragGesture.Value) {
        guard showsInlinePanel, !isCardDismissDragActive, !ignoresCurrentDrag else {
            return
        }

        let translation = value.translation
        if !isTrackingSoundLab {
            guard !NowPlayingDragIntent.shouldSoundLabYieldToCardDismiss(translation: translation) else {
                ignoresCurrentDrag = true
                return
            }

            guard let nextState = startingSoundLabState(with: value) else {
                return
            }

            interactionState = nextState
            isSoundLabInteractionActive = true
        }

        let baseProgress: CGFloat = isOpen ? 1 : 0
        let verticalAssist = max(0, -translation.height) / (revealDistance * 4)
        let nextProgress = (baseProgress - translation.width / revealDistance + verticalAssist).clamped01
        withTransaction(\.disablesAnimations, true) {
            revealProgress = nextProgress
        }
    }

    private func finishSoundLabDrag(_ value: DragGesture.Value) {
        defer {
            ignoresCurrentDrag = false
        }

        // Below the floor nothing tracks the drag, so a cancelled one leaves
        // no state behind; a release that would have opened the panel asks
        // for the sheet.
        guard showsInlinePanel else {
            if releaseOpensBelowFloor(value) {
                onRequestSoundLabSheet()
            }
            return
        }

        guard isTrackingSoundLab else {
            isSoundLabInteractionActive = false
            return
        }

        let baseProgress: CGFloat = isOpen ? 1 : 0
        let predictedProgress = (baseProgress - value.predictedEndTranslation.width / revealDistance).clamped01
        let shouldOpen = if isOpen {
            !(revealProgress < 0.52 || predictedProgress < 0.36)
        } else {
            revealProgress > Self.openingProgress || predictedProgress > Self.openingPredictedProgress
        }

        snap(open: shouldOpen)
    }

    private func releaseOpensBelowFloor(_ value: DragGesture.Value) -> Bool {
        let translation = value.translation
        guard !isCardDismissDragActive,
              !NowPlayingDragIntent.shouldSoundLabYieldToCardDismiss(translation: translation),
              startingSoundLabState(with: value) == .openingDrag
        else {
            return false
        }
        let verticalAssist = max(0, -translation.height) / (revealDistance * 4)
        let progress = (-translation.width / revealDistance + verticalAssist).clamped01
        let predictedProgress = (-value.predictedEndTranslation.width / revealDistance).clamped01
        return progress > Self.openingProgress || predictedProgress > Self.openingPredictedProgress
    }

    private func startingSoundLabState(with value: DragGesture.Value) -> NowPlayingSoundLabInteractionState? {
        let translation = value.translation
        let width = translation.width
        let height = translation.height
        let startsNearSoundLabEdge = value.startLocation.x > size * 0.36
        let horizontalBias = startsNearSoundLabEdge ? 0.35 : 0.70

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
        guard showsInlinePanel else {
            if open {
                onRequestSoundLabSheet()
            }
            return
        }
        snap(open: open)
    }

    private func snap(open: Bool) {
        let target: CGFloat = open ? 1 : 0
        guard isOpen != open || abs(revealProgress - target) > 0.0001 else {
            interactionState = .settled(open: open)
            isSoundLabInteractionActive = false
            return
        }

        interactionState = .settling(targetOpen: open)
        feedbackTrigger.toggle()
        isSoundLabInteractionActive = open
        let animation: Animation = reduceMotion
            ? .easeOut(duration: 0.18)
            : .interactiveSpring(response: 0.32, dampingFraction: 0.86)
        withAnimation(animation) {
            revealProgress = target
        } completion: {
            finishSettle(open: open)
        }
    }

    private func finishSettle(open: Bool) {
        guard case .settling(targetOpen: let targetOpen) = interactionState,
              targetOpen == open
        else {
            return
        }

        interactionState = .settled(open: open)
        isSoundLabInteractionActive = false
    }

    private func loadedArtworkImage(for request: ArtworkRequest?) -> UIImage? {
        guard let request else {
            return nil
        }

        return imageState.resolvedImage(for: request)
    }
}
