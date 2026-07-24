import SwiftUI

struct NowPlayingSoundLabArtwork: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale

    let title: String
    let imageURL: String?
    let size: CGFloat
    @Binding var voiceBoostEnabled: Bool
    let voiceBoostControlEnabled: Bool
    let onAdFreePassAction: () -> Void
    let onTranscribeRemotely: () -> Void
    let onShowTranscript: () -> Void
    let onAdFreePassBackgroundProbe: () -> Void
    @Binding var isSoundLabInteractionActive: Bool
    let isCardDismissDragActive: Bool

    @State private var interactionState = NowPlayingSoundLabInteractionState.closed
    @State private var revealProgress: CGFloat = 0
    @State private var ignoresCurrentDrag = false
    @State private var feedbackTrigger = false
    @State private var imageState = ArtworkImageState()

    private let cornerRadius: CGFloat = 8

    var body: some View {
        let request = artworkRequest
        let artworkImage = loadedArtworkImage(for: request)

        ZStack {
            if shouldRenderSoundLabPanel {
                NowPlayingSoundLabPanelHost(
                    revealProgress: revealProgress,
                    voiceBoostEnabled: $voiceBoostEnabled,
                    voiceBoostControlEnabled: voiceBoostControlEnabled,
                    onAdFreePassAction: onAdFreePassAction,
                    onTranscribeRemotely: onTranscribeRemotely,
                    onShowTranscript: onShowTranscript,
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
                .offset(
                    x: -size
                        * (1 - NowPlayingSoundLabLayout.artworkVisibleFraction)
                        * revealProgress
                )
                .allowsHitTesting(false)
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(.white.opacity(edgeStrokeOpacity), lineWidth: 1)
                .accessibilityHidden(true)
        }
        .overlay(alignment: soundLabHitAlignment) {
            Color.clear
                .frame(width: soundLabHitWidth, height: size)
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
                .simultaneousGesture(soundLabGesture)
        }
        .sensoryFeedback(.selection, trigger: feedbackTrigger)
        .task(id: request) {
            _ = await imageState.loadArtwork(for: request, cacheKind: .episode)
        }
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

    private var shouldRenderSoundLabPanel: Bool {
        switch interactionState {
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

    private var soundLabHitWidth: CGFloat {
        if isOpen, !isTrackingSoundLab {
            return max(94, size * 0.34)
        }

        return size
    }

    private var soundLabHitAlignment: Alignment {
        isOpen && !isTrackingSoundLab ? .leading : .center
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
        guard !isCardDismissDragActive, !ignoresCurrentDrag else {
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
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            revealProgress = nextProgress
        }
    }

    private func finishSoundLabDrag(_ value: DragGesture.Value) {
        defer {
            ignoresCurrentDrag = false
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
            revealProgress > 0.22 || predictedProgress > 0.30
        }

        snap(open: shouldOpen)
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
