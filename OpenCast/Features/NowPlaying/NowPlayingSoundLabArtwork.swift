import SwiftUI

struct NowPlayingSoundLabArtwork: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.layoutDirection) private var layoutDirection
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
    /// The card around the square. Without one the panel keeps the square.
    var openContext: NowPlayingSoundLabOpenPanel.CardContext?

    @State private var interactionState = NowPlayingSoundLabInteractionState.closed
    @State private var revealProgress: CGFloat = 0
    @State private var ignoresCurrentDrag = false
    /// Which gesture an invalidation consumed. A reference, because a gesture
    /// writes it from its own delivery, where nothing may redraw.
    @State private var dragOwnership = DragOwnershipBox()
    @State private var feedbackTrigger = false
    @State private var imageState = ArtworkImageState()
    /// The square in the card's coordinates, and the heading's whole height:
    /// what a closed panel resolves from. They stay measured while it is open,
    /// to tell whether its key still holds.
    @State private var squareFrame: CGRect?
    @State private var headingReading: HeadingReading?
    /// What the panel opened with, from before the first frame of a reveal to
    /// its settled closure. While this is held nothing resolves the panel.
    @State private var keptPanel: KeptPanel?
    /// Whether the last capture was legacy: the reveal layer then draws the
    /// artwork, closed included, until the next capture.
    @State private var keepsLegacyArtwork = false
    /// An opening request waiting for the measurements a titled panel needs.
    @State private var waitsToOpen = false
    /// Tells a settle's completion from a later reveal's.
    @State private var settleGeneration = 0
    /// The space the drag in progress began reading, kept for that drag.
    @GestureState private var dragReadsFootprint: Bool? = nil

    /// Consumption belongs to a gesture. The gesture that was revealing an
    /// invalidated panel does nothing more, its end included; any later one
    /// takes its own identity in its own first delivery, so its first update
    /// is handled with nothing having to let it through.
    struct DragOwnership {
        /// Kept past the gesture's flight: its end can follow its latch's reset.
        private var latest = 0
        private var isInFlight = false
        private var consumed: Int?

        var consumesCurrentGesture: Bool {
            consumed == latest
        }

        mutating func gestureBegan() {
            latest += 1
            isInFlight = true
        }

        mutating func gestureReset() {
            isInFlight = false
        }

        /// A drag still tracking is that gesture, its latch reset or not.
        mutating func invalidate(isTracking: Bool) {
            if isInFlight || isTracking {
                consumed = latest
            }
        }
    }

    private final class DragOwnershipBox {
        var value = DragOwnership()
    }

    private struct KeptPanel: Equatable {
        let panel: NowPlayingSoundLabOpenPanel
        let key: NowPlayingSoundLabOpenPanel.ShapeKey
    }

    /// A height, and the environment it was measured in: an environment that
    /// happens to give the same height still reads as a new measurement.
    private nonisolated struct HeadingReading: Equatable {
        let height: CGFloat
        let dynamicTypeSize: DynamicTypeSize
        let displayScale: CGFloat
    }

    private let cornerRadius: CGFloat = 8
    private let edgeStrokeWidth: CGFloat = 1
    /// A titled panel's drags read this space: the target moves between the
    /// square and the open rectangle, and a space that moved with it would
    /// feed the drag. The square's drags read `.local`, as they always have.
    private static let footprintCoordinateSpace = "NowPlayingSoundLabFootprint"
    /// A release opens the panel past this much of the reveal, or past
    /// `openingPredictedProgress` of it by the drag's predicted end.
    private static let openingProgress: CGFloat = 0.22
    private static let openingPredictedProgress: CGFloat = 0.30

    var body: some View {
        let request = artworkRequest
        let loadingRequest = appModel.isNowPlayingPresented ? request : nil
        let artworkImage = loadedArtworkImage(for: request)

        // Nil is closed, in the very body that first sees a changed key:
        // nothing stored decides whether an invalid panel is drawn.
        let presented = presentedPanel
        let revealsPanel = presented != nil
        let displaysRevealArtwork = revealsPanel || keepsLegacyArtwork
        let reveal = revealsPanel ? revealProgress : 0
        let openPanel = presented ?? .legacy(side: size)
        let open = openPanel.frame.size
        let revealed = CGSize(
            width: size + (open.width - size) * reveal,
            height: size + (open.height - size) * reveal
        )
        let exposedWidth = NowPlayingSoundLabLayout(panelWidth: open.width).artworkExposedWidth
        let hitFrame = openPanel.artworkHitFrame(side: size, isSettledOpen: isOpen && !isTrackingSoundLab)
        let measuresSquare = opensBeyondSquare
        let gestureMode = presented?.mode ?? (resolvedOpenPanel ?? .legacy(side: size)).mode

        // Two layers, so that a closing reveal can go at once while the
        // square keeps the layout's own motion: a single view's old rectangle
        // would be the reveal's. Only the visibility skips animation. A legacy
        // capture is never invalidated by a shape-key change; reset can still
        // close it immediately, so `keepsLegacyArtwork` leaves the drawing to
        // the reveal layer from a legacy capture until the next capture.
        //
        // The square never unmounts: a view mounted during a resize starts at
        // the model's value, and showing it would cut the resize short. After
        // a legacy capture it shares no drawn frame with the reveal layer,
        // because a layer on a legacy panel's exact frame, accessibility-hidden
        // or not, puts the panel ahead of the artwork in the accessibility
        // order. A render-only move restored the order and padding the layout
        // frame did not, so it is the drawn geometry. That is observed, not
        // understood, and the amount is arbitrary. The move is keyed to the
        // capture and not to visibility because an offset rides any animation
        // its update carries: it must not change in the update that shows the
        // square.
        ZStack(alignment: .bottom) {
            framedArtwork(width: size, height: size, strokeInset: 0) {
                NowPlayingArtworkImageView(title: title, image: artworkImage)
                    .frame(width: size, height: size)
            }
            .animation(nil) { $0.opacity(displaysRevealArtwork ? 0 : 1) }
            .offset(y: keepsLegacyArtwork ? 1 : 0)
            .allowsHitTesting(false)

            framedArtwork(
                width: revealed.width,
                height: revealed.height,
                strokeInset: openPanel.mode == .legacy ? 0 : edgeStrokeWidth / 2 * reveal
            ) {
                if revealsPanel, shouldRenderSoundLabPanel {
                    NowPlayingSoundLabPanelHost(
                        presentation: .inline(revealProgress: revealProgress, titledRows: openPanel.titledRows),
                        voiceBoostEnabled: $voiceBoostEnabled,
                        voiceBoostControlEnabled: voiceBoostControlEnabled,
                        onAdFreePassAction: onAdFreePassAction,
                        onTranscribeRemotely: onTranscribeRemotely,
                        onTranscriptAction: onTranscriptAction,
                        onAdFreePassBackgroundProbe: onAdFreePassBackgroundProbe
                    )
                    .frame(width: open.width, height: open.height)
                    .opacity(panelOpacity)
                    .scaleEffect(panelScale, anchor: .trailing)
                    .offset(x: panelOffset)
                    .allowsHitTesting(revealProgress > 0.82)
                    .accessibilityHidden(revealProgress < 0.65)
                }

                NowPlayingArtworkImageView(title: title, image: artworkImage)
                    .frame(width: revealed.height, height: revealed.height)
                    .opacity(1 - 0.10 * Double(reveal))
                    .offset(x: -((open.width + open.height) / 2 - exposedWidth) * reveal)
                    .allowsHitTesting(false)
            }
            .animation(nil) { $0.opacity(displaysRevealArtwork ? 1 : 0) }
        }
        // The footprint: the visual subtree overflows it upward and to both
        // sides, and nothing around the artwork ever sees that.
        .frame(width: size, height: size, alignment: .bottom)
        .onGeometryChange(for: CGRect?.self) { geometry in
            measuresSquare ? geometry.frame(in: .named(NowPlayingSoundLabOpenPanel.CardContext.coordinateSpaceName)) : nil
        } action: { frame in
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                squareFrame = frame
            }
        }
        .background {
            headingMeasurement
        }
        .overlay(alignment: .leading) {
            Color.clear
                .frame(width: hitFrame.width, height: hitFrame.height)
                .contentShape(.rect(cornerRadius: cornerRadius))
                .offset(x: hitFrame.minX, y: hitFrame.midY - size / 2)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Artwork for \(title)")
                .accessibilityValue(isOpen ? "Visual settings shown" : "Visual settings hidden")
                .accessibilityHint(accessibilityHint)
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("Now Playing Artwork")
                .accessibilityAction(named: "Show Visual Settings", showVisualSettings)
                .accessibilityAction(named: "Hide Visual Settings", hideVisualSettings)
                .onTapGesture(perform: toggleVisualSettings)
                .simultaneousGesture(soundLabGesture(mode: gestureMode))
        }
        .coordinateSpace(.named(Self.footprintCoordinateSpace))
        .sensoryFeedback(.selection, trigger: feedbackTrigger)
        .onAppear(perform: applyPinnedReveal)
        .onDisappear(perform: abandonInteraction)
        .onChange(of: appModel.isNowPlayingPresented) { _, isPresented in
            if !isPresented { resetInteraction() }
        }
        .onChange(of: showsInlinePanel) { _, showsInline in
            if !showsInline { resetInteraction() }
        }
        .onChange(of: isOpenPanelReady) { _, isReady in
            if isReady { openWhenReady() }
        }
        .onChange(of: isKeptPanelInvalid) { _, isInvalid in
            if isInvalid { invalidateKeptPanel() }
        }
        .onChange(of: dragReadsFootprint) { _, latched in
            guard latched == nil else {
                return
            }
            dragOwnership.value.gestureReset()
            let generation = settleGeneration
            Task {
                guard dragReadsFootprint == nil,
                      generation == settleGeneration else {
                    return
                }
                settleEndedDrag()
            }
        }
        .task(id: loadingRequest) {
            // Dismissal pauses loading without dropping the displayed bitmap.
            // Reopening can render it even after the shared cache evicts it.
            guard let loadingRequest else { return }
            _ = await imageState.loadArtwork(for: loadingRequest, cacheKind: .episode)
        }
    }

    /// The image with its clip and edge, one construction for both layers:
    /// the square draws exactly what the reveal draws before it has moved.
    private func framedArtwork(
        width: CGFloat,
        height: CGFloat,
        strokeInset: CGFloat,
        @ViewBuilder content: () -> some View
    ) -> some View {
        ZStack(alignment: .bottom, content: content)
            .frame(width: width, height: height, alignment: .bottom)
            .clipShape(.rect(cornerRadius: cornerRadius))
            .overlay {
                // A panel beyond the square keeps its stroke inside the
                // rectangle its clearance was measured from.
                RoundedRectangle(cornerRadius: cornerRadius)
                    .inset(by: strokeInset)
                    .stroke(.white.opacity(edgeStrokeOpacity), lineWidth: edgeStrokeWidth)
                    .accessibilityHidden(true)
            }
    }

    /// The exact heading, in this environment, outside the artwork's layout.
    @ViewBuilder
    private var headingMeasurement: some View {
        if opensBeyondSquare {
            let dynamicTypeSize = dynamicTypeSize
            let displayScale = displayScale
            NowPlayingSoundLabPanel.paddedHeader
                .fixedSize()
                .hidden()
                .accessibilityHidden(true)
                .onGeometryChange(for: HeadingReading.self) { geometry in
                    HeadingReading(
                        height: geometry.size.height,
                        dynamicTypeSize: dynamicTypeSize,
                        displayScale: displayScale
                    )
                } action: { reading in
                    var transaction = Transaction(animation: nil)
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        headingReading = reading
                    }
                }
        }
    }

    private func resetInteraction() {
        settleGeneration += 1
        withTransaction(\.disablesAnimations, true) {
            keptPanel = nil
            waitsToOpen = false
            interactionState = .closed
            revealProgress = 0
            ignoresCurrentDrag = false
            isSoundLabInteractionActive = false
            applyPinnedReveal()
        }
    }

    /// No feedback, and the drag that was revealing this panel ends here: a
    /// release must neither reopen it nor ask for the sheet.
    private func invalidateKeptPanel() {
        dragOwnership.value.invalidate(isTracking: isTrackingSoundLab)
        resetInteraction()
    }

    /// The artwork is going away: nothing of its interaction may outlive it.
    private func abandonInteraction() {
        guard keptPanel != nil || interactionState != .closed else {
            return
        }
        settleGeneration += 1
        keptPanel = nil
        waitsToOpen = false
        interactionState = .closed
        revealProgress = 0
        isSoundLabInteractionActive = false
    }

    /// The gesture latch resets on success or cancellation.
    /// Deferred cleanup revalidates the latch and reveal generation;
    /// reset alone does not establish whether `onEnded` has run.
    private func settleEndedDrag() {
        ignoresCurrentDrag = false
        if isTrackingSoundLab {
            snap(open: interactionState.intendedOpen)
        }
    }

    /// Takes the capture a reveal opens with, or reuses the one it has.
    /// False when a titled panel's measurements are not there yet.
    private func holdKeptPanel() -> Bool {
        if keptPanel != nil {
            return true
        }
        guard isOpenPanelReady, let panel = resolvedOpenPanel else {
            return false
        }
        keptPanel = KeptPanel(panel: panel, key: shapeKey)
        keepsLegacyArtwork = panel.mode == .legacy
        return true
    }

    private func openWhenReady() {
        applyPinnedReveal()
        if waitsToOpen {
            waitsToOpen = false
            snap(open: true)
        }
    }

    private func applyPinnedReveal() {
        guard let pinnedRevealProgress, showsInlinePanel, holdKeptPanel() else {
            return
        }

        revealProgress = CGFloat(pinnedRevealProgress).clamped01
        interactionState = .open
    }

    private var shapeKey: NowPlayingSoundLabOpenPanel.ShapeKey {
        NowPlayingSoundLabOpenPanel.ShapeKey(
            side: size,
            dynamicTypeSize: dynamicTypeSize,
            reducesMotion: reduceMotion,
            rowCount: rowCount,
            paddedHeadingHeight: headingReading?.height,
            displayScale: displayScale,
            layoutDirection: layoutDirection,
            card: openContext?.shape
        )
    }

    private var rowCount: Int {
        appModel.playback.currentEpisode == nil ? 2 : 3
    }

    private var keptDisposition: NowPlayingSoundLabOpenPanel.Disposition? {
        keptPanel.map {
            NowPlayingSoundLabOpenPanel.disposition(keptMode: $0.panel.mode, keptKey: $0.key, currentKey: shapeKey)
        }
    }

    private var isKeptPanelInvalid: Bool {
        keptDisposition == .invalidate
    }

    /// What is on screen: the panel as it opened, the square for one that
    /// opened as the square, and nil when closed or invalid.
    private var presentedPanel: NowPlayingSoundLabOpenPanel? {
        switch keptDisposition {
        case .keep:
            keptPanel?.panel
        case .followAsLegacy:
            .legacy(side: size)
        case .invalidate, nil:
            nil
        }
    }

    private var isOpen: Bool {
        interactionState.intendedOpen && !isKeptPanelInvalid
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

    private var opensBeyondSquare: Bool {
        openContext != nil
            && NowPlayingSoundLabOpenPanel.isEligible(
                side: size,
                isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
            )
    }

    /// Nothing reveals until the open rectangle is known from measurements of
    /// this square and this heading, so the panel never starts from a
    /// provisional size or a stale one.
    private var isOpenPanelReady: Bool {
        !opensBeyondSquare || (isSquareMeasured && isHeadingMeasured)
    }

    private var isSquareMeasured: Bool {
        guard let squareFrame else {
            return false
        }
        let pixel = 1 / displayScale
        return abs(squareFrame.width - size) <= pixel && abs(squareFrame.height - size) <= pixel
    }

    private var isHeadingMeasured: Bool {
        headingReading?.dynamicTypeSize == dynamicTypeSize && headingReading?.displayScale == displayScale
    }

    /// A closed panel's resolution. Nil only until the first measurements
    /// arrive; never consulted for a panel that is open.
    private var resolvedOpenPanel: NowPlayingSoundLabOpenPanel? {
        guard opensBeyondSquare else {
            return .legacy(side: size)
        }
        guard let openContext, let squareFrame, let paddedHeadingHeight = headingReading?.height else {
            return nil
        }
        let inputs = openContext.inputs(
            square: openContext.leadingRelative(squareFrame, isRightToLeft: layoutDirection == .rightToLeft),
            displayScale: displayScale,
            rowCount: rowCount,
            isAccessibilitySize: dynamicTypeSize.isAccessibilitySize,
            paddedHeadingHeight: paddedHeadingHeight
        )
        return inputs.map(NowPlayingSoundLabOpenPanel.init) ?? .legacy(side: size)
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

    /// Whether a drag reads the footprint space: the space it latched, or
    /// before it has latched one, the space of the panel's mode.
    static func readsFootprint(latched: Bool?, mode: NowPlayingSoundLabOpenPanel.Mode) -> Bool {
        latched ?? (mode != .legacy)
    }

    private func soundLabGesture(mode: NowPlayingSoundLabOpenPanel.Mode) -> some Gesture {
        let readsFootprint = Self.readsFootprint(latched: dragReadsFootprint, mode: mode)
        var drag = DragGesture(minimumDistance: 1, coordinateSpace: .local)
        if readsFootprint {
            drag.coordinateSpace = .named(Self.footprintCoordinateSpace)
        }

        let ownership = dragOwnership
        return drag
            .updating($dragReadsFootprint) { _, state, _ in
                if state == nil {
                    state = readsFootprint
                    ownership.value.gestureBegan()
                }
            }
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
        guard showsInlinePanel,
              !isCardDismissDragActive,
              !ignoresCurrentDrag,
              !dragOwnership.value.consumesCurrentGesture
        else {
            return
        }

        let translation = value.translation
        if !isTrackingSoundLab {
            guard !NowPlayingDragIntent.shouldSoundLabYieldToCardDismiss(translation: translation) else {
                ignoresCurrentDrag = true
                return
            }

            guard let nextState = startingSoundLabState(with: value),
                  nextState != .openingDrag || holdKeptPanel()
            else {
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

        guard !dragOwnership.value.consumesCurrentGesture else {
            return
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
        requestSnap(open: !isOpen && !waitsToOpen)
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
        guard !open || keptPanel != nil || isOpenPanelReady else {
            waitsToOpen = true
            return
        }
        waitsToOpen = false
        snap(open: open)
    }

    /// What a snap does from where the interaction stands.
    enum SnapStep {
        case leaveSettling
        case release
        case animate
    }

    /// A close's model reveal is at zero while its motion runs, so a repeated
    /// Hide must not read as already at the target.
    static func snapStep(
        open: Bool,
        state: NowPlayingSoundLabInteractionState,
        isOpen: Bool,
        revealProgress: CGFloat
    ) -> SnapStep {
        if !open, state == .settling(targetOpen: false) {
            return .leaveSettling
        }
        let target: CGFloat = open ? 1 : 0
        return isOpen != open || abs(revealProgress - target) > 0.0001 ? .animate : .release
    }

    private func snap(open: Bool) {
        guard !open || holdKeptPanel() else {
            return
        }
        switch Self.snapStep(open: open, state: interactionState, isOpen: isOpen, revealProgress: revealProgress) {
        case .leaveSettling:
            return
        case .release:
            interactionState = .settled(open: open)
            isSoundLabInteractionActive = false
            if !open {
                keptPanel = nil
            }
            return
        case .animate:
            break
        }

        let target: CGFloat = open ? 1 : 0
        interactionState = .settling(targetOpen: open)
        feedbackTrigger.toggle()
        isSoundLabInteractionActive = open
        let animation: Animation = reduceMotion
            ? .easeOut(duration: 0.18)
            : .interactiveSpring(response: 0.32, dampingFraction: 0.86)
        settleGeneration += 1
        let generation = settleGeneration
        withAnimation(
            animation,
            completionCriteria: open ? .logicallyComplete : .removed
        ) {
            revealProgress = target
        } completion: {
            finishSettle(open: open, generation: generation)
        }
    }

    private func finishSettle(open: Bool, generation: Int) {
        guard generation == settleGeneration,
              case .settling(targetOpen: let targetOpen) = interactionState,
              targetOpen == open
        else {
            return
        }

        interactionState = .settled(open: open)
        isSoundLabInteractionActive = false
        if !open {
            keptPanel = nil
        }
    }

    private func loadedArtworkImage(for request: ArtworkRequest?) -> UIImage? {
        guard let request else {
            return nil
        }

        return imageState.resolvedImage(for: request)
    }
}
