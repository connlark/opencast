import SwiftUI
import Testing
@testable import OpenCast

/// What an open panel keeps. The disposition is tested on its own; the hosted
/// tests drive one persistent artwork, whose inputs change under it, because
/// a fresh host per step could not show anything being retained. Most hosted
/// tests read settled frames. The resize regression also samples an
/// intermediate drawn width; recorded clips remain the evidence for every-frame
/// behavior.
@MainActor
@Suite("Sound Lab kept panel")
struct NowPlayingSoundLabKeptPanelTests {
    typealias OpenPanel = NowPlayingSoundLabOpenPanel
    typealias Key = NowPlayingSoundLabOpenPanel.ShapeKey
    typealias Fixture = NowPlayingSoundLabOpenPanelTests
    typealias Artwork = NowPlayingSoundLabArtwork

    static let context = OpenPanel.CardContext(
        cardGeometry: NowPlayingCardGeometryTests.closed(),
        contentWidth: 418,
        viewport: CGRect(x: 0, y: 0, width: 466, height: 500)
    )

    static func key(scale: CGFloat = 3) -> Key {
        Key(
            side: Fixture.closedSide,
            dynamicTypeSize: .large,
            reducesMotion: false,
            rowCount: 3,
            paddedHeadingHeight: 25,
            displayScale: scale,
            layoutDirection: .leftToRight,
            card: context.shape
        )
    }

    enum Member: String, CaseIterable, CustomTestStringConvertible {
        case side, dynamicTypeSize, reducesMotion, rowCount, heading, displayScale, layoutDirection
        case cardWidth, contentWidth, viewport, safeTop, moreFrame, occlusions, noCard

        var testDescription: String { rawValue }

        func changing(_ key: Key) -> Key {
            var key = key
            switch self {
            case .side: key.side += 2
            case .dynamicTypeSize: key.dynamicTypeSize = .xLarge
            case .reducesMotion: key.reducesMotion.toggle()
            case .rowCount: key.rowCount = 2
            case .heading: key.paddedHeadingHeight = 27
            case .displayScale: key.displayScale = 2
            case .layoutDirection: key.layoutDirection = .rightToLeft
            case .cardWidth: key.card?.cardWidth += 1
            case .contentWidth: key.card?.contentWidth += 1
            case .viewport: key.card?.viewport.size.height += 1
            case .safeTop: key.card?.safeTop += 1
            case .moreFrame: key.card?.moreFrame.origin.x += 1
            case .occlusions: key.card?.occlusions = []
            case .noCard: key.card = nil
            }
            return key
        }
    }

    @Test("A panel that opened legacy follows under every change of the key", arguments: Member.allCases)
    func legacyFollows(member: Member) {
        let kept = Self.key()
        #expect(OpenPanel.disposition(keptMode: .legacy, keptKey: kept, currentKey: member.changing(kept)) == .followAsLegacy)
        #expect(OpenPanel.disposition(keptMode: .legacy, keptKey: kept, currentKey: kept) == .followAsLegacy)
    }

    @Test("A titled panel is invalidated by each member of the key alone", arguments: Member.allCases)
    func titledInvalidated(member: Member) {
        let kept = Self.key()
        let current = member.changing(kept)
        #expect(OpenPanel.disposition(keptMode: .headed, keptKey: kept, currentKey: current) == .invalidate)
        #expect(OpenPanel.disposition(keptMode: .headingless, keptKey: kept, currentKey: current) == .invalidate)
    }

    @Test("The square's position and the pixel grid's origin are not in the key")
    func positionIsNotInTheKey() throws {
        let key = Self.key()
        let card = try #require(key.card)
        let members = Mirror(reflecting: key).children.compactMap(\.label)
            + Mirror(reflecting: card).children.compactMap(\.label)
        #expect(members.sorted() == [
            "card", "cardWidth", "contentWidth", "displayScale", "dynamicTypeSize", "layoutDirection", "moreFrame",
            "occlusions", "paddedHeadingHeight", "reducesMotion", "rowCount", "safeTop", "side", "viewport"
        ])

        // One card in two places: every member of the context but the grid's origin is equal.
        let contexts = [CGFloat(0), 233.5].map { x in
            OpenPanel.CardContext(
                cardGeometry: NowPlayingCardGeometry(
                    allocation: CGRect(x: x, y: 0, width: 466, height: 678),
                    windowSize: CGSize(width: 1000, height: 678),
                    safeAreaInsets: EdgeInsets(),
                    isAccessibilitySize: false,
                    pose: .regularFlat,
                    occlusions: []
                ),
                contentWidth: 418,
                viewport: CGRect(x: 0, y: 0, width: 466, height: 500)
            )
        }
        #expect(contexts[0].pixelGridOrigin != contexts[1].pixelGridOrigin)
        #expect(contexts[0].shape == contexts[1].shape)
        var moved = key
        moved.card = contexts[1].shape
        var kept = key
        kept.card = contexts[0].shape
        #expect(OpenPanel.disposition(keptMode: .headed, keptKey: kept, currentKey: moved) == .keep)
    }

    @Test("After a consumed gesture is cancelled, a fresh gesture's first update is not consumed")
    func freshGestureAfterACancelledConsumedOne() {
        var ownership = Artwork.DragOwnership()
        ownership.gestureBegan()
        ownership.invalidate(isTracking: true)
        #expect(ownership.consumesCurrentGesture)
        ownership.gestureReset()

        ownership.gestureBegan()
        #expect(!ownership.consumesCurrentGesture, "its only change callback and its release are both handled")
        ownership.gestureReset()
        #expect(!ownership.consumesCurrentGesture, "and a release after the reset")
    }

    @Test("A consumed gesture's end stays consumed after its latch resets")
    func consumedGesturesLateEnd() {
        var ownership = Artwork.DragOwnership()
        ownership.gestureBegan()
        ownership.invalidate(isTracking: false)
        #expect(ownership.consumesCurrentGesture, "its remaining changes")
        ownership.gestureReset()
        #expect(ownership.consumesCurrentGesture, "its end after its latch has reset")
    }

    @Test("A drag still tracking after its latch has reset is consumed by an invalidation")
    func trackingGestureAfterItsReset() {
        var ownership = Artwork.DragOwnership()
        ownership.gestureBegan()
        ownership.gestureReset()
        ownership.invalidate(isTracking: true)
        #expect(ownership.consumesCurrentGesture)
    }

    @Test("An invalidation with no gesture in flight consumes nothing")
    func invalidationWithNoGesture() {
        var never = Artwork.DragOwnership()
        never.invalidate(isTracking: false)
        #expect(!never.consumesCurrentGesture)
        never.gestureBegan()
        #expect(!never.consumesCurrentGesture)

        var finished = Artwork.DragOwnership()
        finished.gestureBegan()
        finished.gestureReset()
        finished.invalidate(isTracking: false)
        #expect(!finished.consumesCurrentGesture)
    }

    @Test("An invalidation delivered together with a gesture's first latch consumes that gesture")
    func invalidationWithAFirstLatch() {
        var ownership = Artwork.DragOwnership()
        ownership.gestureBegan()
        ownership.gestureReset()
        // The latch is set in the gesture's own delivery, so whichever order the
        // two observers run in afterwards, the gesture is already in flight.
        ownership.gestureBegan()
        ownership.invalidate(isTracking: false)
        #expect(ownership.consumesCurrentGesture)
    }

    @Test("A close already settling is left alone, a repeated Hide included")
    func snapLeavesASettlingClose() {
        #expect(Artwork.snapStep(open: false, state: .settling(targetOpen: false), isOpen: false, revealProgress: 0) == .leaveSettling)
    }

    @Test("A snap already at its target releases")
    func snapReleasesAtTheTarget() {
        #expect(Artwork.snapStep(open: false, state: .closed, isOpen: false, revealProgress: 0) == .release)
        #expect(Artwork.snapStep(open: true, state: .open, isOpen: true, revealProgress: 1) == .release)
        #expect(Artwork.snapStep(open: true, state: .settling(targetOpen: true), isOpen: true, revealProgress: 1) == .release)
    }

    @Test("Any other snap animates")
    func snapAnimatesOtherwise() {
        #expect(Artwork.snapStep(open: false, state: .open, isOpen: true, revealProgress: 1) == .animate)
        #expect(Artwork.snapStep(open: true, state: .closed, isOpen: false, revealProgress: 0) == .animate)
        // Reversals of a settle, each way.
        #expect(Artwork.snapStep(open: true, state: .settling(targetOpen: false), isOpen: false, revealProgress: 0) == .animate)
        #expect(Artwork.snapStep(open: false, state: .settling(targetOpen: true), isOpen: true, revealProgress: 1) == .animate)
        // A release partway, the state agreeing with the target and the reveal not there.
        #expect(Artwork.snapStep(open: false, state: .openingDrag, isOpen: false, revealProgress: 0.1) == .animate)
        #expect(Artwork.snapStep(open: true, state: .closingDrag, isOpen: true, revealProgress: 0.8) == .animate)
    }

    @Test("Side and heading hold within one pixel and not beyond", arguments: [CGFloat(2), 3])
    func onePixelTolerance(scale: CGFloat) {
        let kept = Self.key(scale: scale)
        let pixel = 1 / scale
        for offset in [pixel, -pixel] {
            var side = kept
            side.side += offset
            #expect(OpenPanel.disposition(keptMode: .headed, keptKey: kept, currentKey: side) == .keep)
            var heading = kept
            heading.paddedHeadingHeight = 25 + offset
            #expect(OpenPanel.disposition(keptMode: .headed, keptKey: kept, currentKey: heading) == .keep)
        }
        for offset in [pixel * 1.01, -pixel * 1.01] {
            var side = kept
            side.side += offset
            #expect(OpenPanel.disposition(keptMode: .headed, keptKey: kept, currentKey: side) == .invalidate)
            var heading = kept
            heading.paddedHeadingHeight = 25 + offset
            #expect(OpenPanel.disposition(keptMode: .headed, keptKey: kept, currentKey: heading) == .invalidate)
        }
    }

    // MARK: One persistent host

    private func host(_ model: KeptPanelHarnessModel) throws -> KeptPanelHost {
        try KeptPanelHost(model: model)
    }

    /// Opened by a pin at appearance, the pin then removed under the same view.
    private func openTitled(_ model: KeptPanelHarnessModel, _ host: KeptPanelHost) throws -> [CGRect] {
        host.settle()
        let rows = host.rendered().rows
        try #require(rows.count == 2, "rows \(rows)")
        model.pin = nil
        host.settle()
        #expect(host.rendered().rows == rows, "removing the pin changes nothing")
        return rows
    }

    @Test("A position past where a closed panel would resolve legacy changes nothing but the position")
    func positionKeeps() throws {
        // Above the safe top's clearance: a closed panel would answer legacy here.
        let top: CGFloat = 4
        let travel = Fixture.closedTop - top
        #expect(OpenPanel(Fixture.closedInputs(square: Fixture.closedSquare(top: top), rowCount: 2)).mode == .legacy)
        let model = KeptPanelHarnessModel(pin: 1)
        let host = try host(model)
        defer { host.close() }
        let rows = try openTitled(model, host)
        let below = try #require(model.below)
        model.isInteractionActive = true

        model.top = top
        host.settle()

        let moved = host.rendered().rows
        try #require(moved.count == rows.count, "rows \(moved)")
        for (now, before) in zip(moved, rows) {
            #expect(abs(now.width - before.width) <= 0.001 && abs(now.height - before.height) <= 0.001)
            #expect(abs(now.minX - before.minX) <= 0.001)
            #expect(abs(now.minY - (before.minY - travel)) <= 0.001)
        }
        let movedBelow = try #require(model.below)
        #expect(abs(movedBelow.minY - (below.minY - travel)) <= 0.001)
        #expect(abs(movedBelow.height - below.height) <= 0.001)
        #expect(model.isInteractionActive, "a move is not an invalidation")
    }

    @Test("A changed side closes the panel, and its return does not bring it back", arguments: [CGFloat(280.8), 200])
    func sideInvalidates(side: CGFloat) throws {
        let model = KeptPanelHarnessModel(pin: 1)
        let host = try host(model)
        defer { host.close() }
        _ = try openTitled(model, host)
        model.isInteractionActive = true

        model.side = side
        host.settle()
        #expect(host.rendered().rows.isEmpty)
        let artwork = try #require(model.artwork)
        #expect(abs(artwork.width - side) <= 0.001 && abs(artwork.height - side) <= 0.001)
        #expect(!model.isInteractionActive)

        model.side = Fixture.closedSide
        host.settle()
        #expect(host.rendered().rows.isEmpty, "the key's return does not resurrect the reveal")
        #expect(!model.isInteractionActive)
    }

    @Test("A partway reveal is closed by a changed key like an open one", arguments: [0.25, 0.5, 0.75])
    func partwayInvalidates(reveal: Double) throws {
        let model = KeptPanelHarnessModel(pin: reveal)
        let host = try host(model)
        defer { host.close() }
        host.settle()
        model.pin = nil
        model.isInteractionActive = true

        model.side = 200
        host.settle()
        #expect(host.rendered().rows.isEmpty)
        #expect(!model.isInteractionActive)
    }

    @Test("A text-size change closes the panel, and a fresh opening resolves for the new size")
    func textSizeInvalidates() throws {
        let model = KeptPanelHarnessModel(pin: 1)
        let host = try host(model)
        defer { host.close() }
        _ = try openTitled(model, host)

        model.dynamicTypeSize = .medium
        host.settle()
        #expect(host.rendered().rows.isEmpty)

        model.pin = 1
        model.showsArtwork = false
        host.settle()
        model.showsArtwork = true
        host.settle()
        #expect(host.rendered().rows.count == 2, "stale measurements give way to fresh ones, then the pin opens")
    }

    @Test("A persistent pin opens again once the new side's measurements are in")
    func persistentPinReapplies() throws {
        let model = KeptPanelHarnessModel(pin: 1)
        let host = try host(model)
        defer { host.close() }
        host.settle()
        let rows = host.rendered().rows
        try #require(rows.count == 2)

        model.side = 200
        host.settle()
        let reopened = host.rendered().rows
        try #require(reopened.count == 2, "rows \(reopened)")
        #expect(reopened != rows)
        let artwork = try #require(model.artwork)
        #expect(abs(artwork.width - 200) <= 0.001 && abs(artwork.height - 200) <= 0.001)
    }

    @Test("A persistent pin reapplies when readiness stays true across a changed key")
    func persistentPinReappliesWhenReadinessStaysTrue() throws {
        let model = KeptPanelHarnessModel(pin: 1)
        let host = try host(model)
        defer { host.close() }
        host.settle()
        let titled = host.rendered().rows
        let square = try #require(model.artwork)
        try #require(titled.count == 2, "rows \(titled)")
        #expect(titled.allSatisfy { $0.maxX > square.maxX }, "titled past the square: \(titled)")

        // With no card the square needs no measurement, so the panel is ready
        // on both sides of the change and only the key differs.
        model.hasCard = false
        host.settle()
        let rendered = host.rendered()
        try #require(rendered.rows.count == 2, "rows \(rendered.rows)")
        #expect(rendered.rows.allSatisfy { $0.maxX <= square.maxX + rendered.pixel }, "reopened as the square: \(rendered.rows)")
    }

    @Test("A panel that opened legacy stays the square while its square becomes eligible; the next open is titled")
    func legacyStaysLegacy() throws {
        let model = KeptPanelHarnessModel(pin: 1, side: 280.8)
        let host = try host(model)
        defer { host.close() }
        host.settle()
        model.pin = nil
        host.settle()
        try #require(host.rendered().rows.count == 2)

        model.side = Fixture.closedSide
        host.settle()
        let rendered = host.rendered()
        let artwork = try #require(model.artwork)
        let inside = rendered.rows.map { $0.maxX <= artwork.maxX + rendered.pixel }
        #expect(rendered.rows.count == 2, "still open")
        #expect(inside == [true, true], "still the square: \(rendered.rows) in \(artwork)")

        model.appModel.isNowPlayingPresented = false
        host.settle()
        #expect(host.rendered().rows.isEmpty, "dismissal releases it")
        model.appModel.isNowPlayingPresented = true
        model.pin = 1
        model.showsArtwork = false
        host.settle()
        model.showsArtwork = true
        host.settle()
        let titled = host.rendered().rows
        try #require(titled.count == 2, "rows \(titled)")
        let reopened = try #require(model.artwork)
        #expect(titled.allSatisfy { $0.maxX > reopened.maxX }, "titled past the square: \(titled)")
    }

    @Test("Dismissal releases the capture and the interaction")
    func dismissalReleases() throws {
        let model = KeptPanelHarnessModel(pin: 1)
        let host = try host(model)
        defer { host.close() }
        _ = try openTitled(model, host)
        model.isInteractionActive = true

        model.appModel.isNowPlayingPresented = false
        host.settle()
        #expect(host.rendered().rows.isEmpty)
        #expect(!model.isInteractionActive)
    }

    @Test("An artwork that goes away leaves no interaction owned behind it")
    func ownerGoneReleases() throws {
        let model = KeptPanelHarnessModel(pin: 1)
        let host = try host(model)
        defer { host.close() }
        _ = try openTitled(model, host)
        model.isInteractionActive = true

        model.showsArtwork = false
        host.settle()
        #expect(!model.isInteractionActive)

        model.showsArtwork = true
        host.settle()
        #expect(host.rendered().rows.isEmpty, "a new artwork starts closed")
    }

    @Test(
        "The closed square draws exactly what the reveal draws at zero",
        arguments: [
            (side: CGFloat(280.8), hasCard: false),
            (side: CGFloat(280.8), hasCard: true),
            (side: Fixture.closedSide, hasCard: true),
            (side: CGFloat(200), hasCard: true)
        ]
    )
    func closedMatchesRevealAtZero(side: CGFloat, hasCard: Bool) throws {
        func pixels(pin: Double?, showsArtwork: Bool = true) throws -> Data {
            let model = KeptPanelHarnessModel(pin: pin, side: side, hasCard: hasCard, showsArtwork: showsArtwork)
            let host = try host(model)
            defer { host.close() }
            host.settle()
            return try #require(host.pixels())
        }
        let closed = try pixels(pin: nil)
        let reveal = try pixels(pin: 0)
        let empty = try pixels(pin: nil, showsArtwork: false)
        #expect(closed == reveal, "byte for byte")
        #expect(closed != empty, "the comparison sees the artwork")
    }

    @Test("Resetting a legacy panel restores the settled closed square", arguments: [false, true])
    func legacyClosureRedrawsTheSquare(hasCard: Bool) throws {
        let neverOpened = try host(KeptPanelHarnessModel(pin: nil, side: 280.8, hasCard: hasCard))
        neverOpened.settle()
        let closed = try #require(neverOpened.pixels())
        neverOpened.close()

        let model = KeptPanelHarnessModel(pin: 1, side: 280.8, hasCard: hasCard)
        let host = try host(model)
        defer { host.close() }
        host.settle()
        model.pin = nil
        host.settle()
        try #require(host.rendered().rows.count == 2)
        #expect(try #require(host.pixels()) != closed, "the comparison sees the panel")

        model.appModel.isNowPlayingPresented = false
        host.settle()
        model.appModel.isNowPlayingPresented = true
        host.settle()
        #expect(host.rendered().rows.isEmpty)
        #expect(try #require(host.pixels()) == closed, "byte for byte")
    }

    /// Samples a long animation at one-third of its duration.
    /// The bounds allow rendered progress between one-eighth and three-quarters.
    fileprivate static let resizeDuration: TimeInterval = 9

    @Test("A reset falling inside the artwork's resize leaves the resize running")
    func legacyResetPreservesArtworkResize() throws {
        let side: CGFloat = 280.8
        let target: CGFloat = 100
        try #require(!NowPlayingSoundLabLayout.showsInline(panelSide: target))
        let model = KeptPanelHarnessModel(pin: 1, side: side)
        let host = try host(model)
        defer { host.close() }
        host.settle()
        model.pin = nil
        host.settle()
        try #require(host.rendered().rows.count == 2)
        model.isInteractionActive = true
        let row = model.top + 12

        withAnimation(.linear(duration: Self.resizeDuration)) {
            model.side = target
        }
        host.wait(Self.resizeDuration / 3)

        #expect(!model.isInteractionActive, "the floor reset the panel")
        let inFlight = try #require(host.drawnWidth(atRow: row))
        let span = side - target
        #expect(inFlight > target + span / 4, "not at the target: \(inFlight)")
        #expect(inFlight < side - span / 8, "not at the old side: \(inFlight)")

        host.wait(Self.resizeDuration)
        let settled = try #require(host.drawnWidth(atRow: row))
        #expect(abs(settled - target) <= 2, "the read sees the square: \(settled)")
    }

    /// The player's column animates its failure state from an ancestor, so
    /// a key change can arrive in an update that already carries an animation.
    /// The square shown by it stands where the footprint puts it, and keeps
    /// the layout's own motion. This stages Retry's update in the harness; the
    /// recorded Retry clip is the proof.
    @Test("A change under the column's animation shows the square in its place, its resize running")
    func invalidationUnderColumnAnimationKeepsSquareInPlace() throws {
        let side: CGFloat = 200
        let target: CGFloat = 280.8
        let model = KeptPanelHarnessModel(pin: 1, side: side)
        let host = try host(model)
        defer { host.close() }
        _ = try openTitled(model, host)
        let row = model.top + 12

        model.columnState.toggle()
        model.side = target
        host.wait(Self.resizeDuration / 3)

        let top = try #require(host.drawnTop(atColumn: 233))
        #expect(abs(top - model.top) <= 1 / 3 + 0.001, "in its place: \(top) against \(model.top)")
        let inFlight = try #require(host.drawnWidth(atRow: row))
        let span = target - side
        #expect(inFlight > side + span / 8, "not at the old side: \(inFlight)")
        #expect(inFlight < target - span / 4, "not at the target: \(inFlight)")

        host.wait(Self.resizeDuration)
        let settled = try #require(host.drawnWidth(atRow: row))
        #expect(abs(settled - target) <= 2, "the read sees the square: \(settled)")
    }

    /// How the capture ends. A hosted test cannot synthesize a drag, so
    /// `releasedAtZero` ends through `resetInteraction` and not `snap`'s
    /// `.release`; both leave no capture, with the reveal at zero.
    enum TitledEnding: String, CaseIterable, CustomTestStringConvertible {
        case releasedAtZero, invalidated

        var testDescription: String { rawValue }
        /// A pin of zero is a capture with nothing revealed.
        var pin: Double { self == .releasedAtZero ? 0 : 1 }
    }

    @Test("A titled capture after a legacy one, ended inside the artwork's resize, leaves the resize running", arguments: TitledEnding.allCases)
    func titledCaptureAfterLegacyKeepsResize(ending: TitledEnding) throws {
        let side: CGFloat = 280.8
        let target: CGFloat = 200
        let model = KeptPanelHarnessModel(pin: 1, side: side)
        let host = try host(model)
        defer { host.close() }
        host.settle()
        model.pin = nil
        host.settle()
        try #require(host.rendered().rows.count == 2)
        func reset() {
            model.appModel.isNowPlayingPresented = false
            host.wait(Self.resizeDuration / 36)
            model.appModel.isNowPlayingPresented = true
            host.wait(Self.resizeDuration / 36)
        }
        reset()
        try #require(host.rendered().rows.isEmpty, "closed after a legacy panel")
        let row = model.top + 12

        withAnimation(.linear(duration: Self.resizeDuration)) {
            model.side = target
        }
        host.wait(Self.resizeDuration / 36)

        // A reset is where a pin is applied: the capture falls inside the
        // resize, at the eligible side the layout is heading for.
        model.pin = ending.pin
        reset()
        model.pin = nil
        switch ending {
        case .releasedAtZero:
            reset()
        case .invalidated:
            let artwork = try #require(model.artwork)
            let rows = host.rendered().rows
            try #require(rows.count == 2, "rows \(rows)")
            try #require(rows.allSatisfy { $0.maxX > artwork.maxX }, "titled past the square: \(rows)")
            model.dynamicTypeSize = .xLarge
        }
        host.wait(Self.resizeDuration / 6)

        let inFlight = try #require(host.drawnWidth(atRow: row))
        let span = side - target
        #expect(inFlight > target + span / 4, "not at the target: \(inFlight)")
        #expect(inFlight < side - span / 8, "not at the old side: \(inFlight)")

        host.wait(Self.resizeDuration)
        let settled = try #require(host.drawnWidth(atRow: row))
        #expect(abs(settled - target) <= 2, "the read sees the square: \(settled)")
    }
}

@MainActor
@Observable
final class KeptPanelHarnessModel {
    var side: CGFloat
    var top = NowPlayingSoundLabOpenPanelTests.closedTop
    var pin: Double?
    var hasCard: Bool
    var showsArtwork: Bool
    var dynamicTypeSize = DynamicTypeSize.large
    var isInteractionActive = false
    /// What the column's animation is keyed to, as the player's failure state.
    var columnState = false
    var artwork: CGRect?
    var below: CGRect?
    let appModel = OpenCastAppModel(
        localLibraryCacheStore: SQLiteLocalLibraryCacheStore.inMemory(),
        allowsAutomaticFeedRefresh: false
    )

    init(
        pin: Double?,
        side: CGFloat = NowPlayingSoundLabOpenPanelTests.closedSide,
        hasCard: Bool = true,
        showsArtwork: Bool = true
    ) {
        self.pin = pin
        self.side = side
        self.hasCard = hasCard
        self.showsArtwork = showsArtwork
        appModel.isNowPlayingPresented = true
    }
}

private struct KeptPanelHarness: View {
    @Bindable var model: KeptPanelHarnessModel

    private var space: NamedCoordinateSpace {
        .named(NowPlayingSoundLabOpenPanel.CardContext.coordinateSpaceName)
    }

    var body: some View {
        VStack(spacing: 12) {
            if model.showsArtwork {
                NowPlayingSoundLabArtwork(
                    title: "Show",
                    imageURL: nil,
                    size: model.side,
                    voiceBoostEnabled: .constant(true),
                    voiceBoostControlEnabled: true,
                    onAdFreePassAction: {},
                    onTranscribeRemotely: {},
                    onTranscriptAction: {},
                    onAdFreePassBackgroundProbe: {},
                    onRequestSoundLabSheet: {},
                    isSoundLabInteractionActive: $model.isInteractionActive,
                    isCardDismissDragActive: false,
                    openContext: model.hasCard ? NowPlayingSoundLabKeptPanelTests.context : nil
                )
                .onGeometryChange(for: CGRect.self) { $0.frame(in: space) } action: { model.artwork = $0 }
            }
            Color.clear
                .frame(height: 40)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: space) } action: { model.below = $0 }
        }
        .animation(.linear(duration: NowPlayingSoundLabKeptPanelTests.resizeDuration), value: model.columnState)
        .padding(.top, model.top)
        .padding(.horizontal, 24)
        .frame(width: 466, height: 500, alignment: .top)
        .coordinateSpace(.named(NowPlayingSoundLabOpenPanel.CardContext.coordinateSpaceName))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(model.appModel)
        .environment(\.dynamicTypeSize, model.dynamicTypeSize)
        .environment(\.appStoreSoundLabRevealProgress, model.pin)
    }
}

/// One window for a whole test, so the artwork under test keeps its identity.
@MainActor
final class KeptPanelHost {
    private let window: UIWindow
    private let controller: UIHostingController<KeptPanelHarness>

    init(model: KeptPanelHarnessModel) throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 500, height: 500)
        controller = UIHostingController(rootView: KeptPanelHarness(model: model))
        controller.safeAreaRegions = []
        window.rootViewController = controller
        window.isHidden = false
    }

    func close() {
        window.isHidden = true
    }

    func settle() {
        controller.view.layoutIfNeeded()
        RunLoop.main.run(until: .now.addingTimeInterval(0.3))
        controller.view.layoutIfNeeded()
    }

    func wait(_ seconds: TimeInterval) {
        RunLoop.main.run(until: .now.addingTimeInterval(seconds))
    }

    func rendered() -> NowPlayingSoundLabHostedFitTests.Rendered {
        var views: [(view: UIView, frame: CGRect)] = []
        func collect(_ view: UIView) {
            guard !view.isHidden, view.alpha > 0 else {
                return
            }
            let frame = view.convert(view.bounds, to: window)
            if frame.width > 0, frame.height > 0 {
                views.append((view, frame))
            }
            view.subviews.forEach(collect)
        }
        controller.view.subviews.forEach(collect)
        return NowPlayingSoundLabHostedFitTests.Rendered(
            square: .zero,
            views: views,
            pixel: 1 / window.traitCollection.displayScale
        )
    }

    /// How wide the window's content is drawn along one row, in points. A
    /// frame in flight exists only in the pixels: layout reads its target. Any
    /// difference from the ground counts: the panel's glass is close to it.
    func drawnWidth(atRow row: CGFloat) -> CGFloat? {
        guard let bitmap = bitmap(scale: 1) else {
            return nil
        }
        let y = Int(row)
        let drawn = (0..<bitmap.width).filter { bitmap.differs(x: $0, y: y, from: (0, y)) }
        return drawn.first.flatMap { first in drawn.last.map { CGFloat($0 - first + 1) } }
    }

    /// Where the window's content first shows down one column, in points, to
    /// a third of a point.
    func drawnTop(atColumn column: CGFloat) -> CGFloat? {
        let scale: CGFloat = 3
        guard let bitmap = bitmap(scale: scale) else {
            return nil
        }
        let x = Int(column * scale)
        return (0..<bitmap.height).first { bitmap.differs(x: x, y: $0, from: (x, 0)) }.map { CGFloat($0) / scale }
    }

    private struct Bitmap {
        let data: Data
        let width: Int
        let height: Int
        let bytesPerRow: Int
        let stride: Int

        private func pixel(_ x: Int, _ y: Int) -> Data {
            let start = y * bytesPerRow + x * stride
            return data[start..<(start + stride)]
        }

        func differs(x: Int, y: Int, from ground: (Int, Int)) -> Bool {
            zip(pixel(x, y), pixel(ground.0, ground.1)).contains { abs(Int($0) - Int($1)) > 2 }
        }
    }

    private func bitmap(scale: CGFloat) -> Bitmap? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        guard let cgImage = image.cgImage, let data = cgImage.dataProvider?.data as Data? else {
            return nil
        }
        return Bitmap(
            data: data,
            width: cgImage.width,
            height: cgImage.height,
            bytesPerRow: cgImage.bytesPerRow,
            stride: cgImage.bitsPerPixel / 8
        )
    }

    /// The window as composited, as lossless bytes.
    func pixels() -> Data? {
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        return renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }.pngData()
    }
}
