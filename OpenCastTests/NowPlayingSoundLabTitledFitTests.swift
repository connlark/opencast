import Foundation
import OpenCastCore
import SwiftUI
import Testing
@testable import OpenCast

/// The titled panel and the artwork around it as SwiftUI renders them, read
/// from the UIKit views they render through (`NowPlayingSoundLabHostedFitTests`
/// says why). The square-panel tests stay there: they describe the legacy
/// mode, which receives no card geometry.
@MainActor
@Suite("Sound Lab titled fit")
struct NowPlayingSoundLabTitledFitTests {
    typealias Layout = NowPlayingSoundLabLayout
    typealias OpenPanel = NowPlayingSoundLabOpenPanel
    typealias Hosted = NowPlayingSoundLabHostedFitTests
    typealias Fixture = NowPlayingSoundLabOpenPanelTests

    static func paddedHeadingHeight(_ size: DynamicTypeSize) -> CGFloat {
        UIHostingController(rootView: NowPlayingSoundLabPanel.paddedHeader.environment(\.dynamicTypeSize, size))
            .sizeThatFits(in: CGSize(width: CGFloat.infinity, height: .infinity))
            .height
    }

    /// The done state: both action rows carry their state glyph.
    static func donePanel(_ open: OpenPanel, dynamicTypeSize: DynamicTypeSize) -> some View {
        NowPlayingSoundLabPanel(
            presentation: .inline(revealProgress: 1, titledRows: open.titledRows),
            voiceBoostEnabled: .constant(true),
            voiceBoostControlEnabled: true,
            adFreePassRow: NowPlayingSoundLabAdFreePassRowModel(presentation: .completed(zoneCount: 2)),
            transcriptionRow: NowPlayingSoundLabTranscriptionRowModel(
                hasCompletedTranscript: true,
                mode: .local,
                remoteActivity: .none,
                localActivity: .none
            ),
            onAdFreePassAction: {},
            onTranscribeRemotely: {},
            onTranscriptAction: {},
            onAdFreePassBackgroundProbe: {}
        )
        .frame(width: open.frame.width, height: open.frame.height)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.dynamicTypeSize, dynamicTypeSize)
    }

    /// The rows top to bottom, each rendered capsule the row's height and
    /// inside the panel, neighbours apart by the gap, the switch in its row.
    static func expectRows(
        _ rendered: Hosted.Rendered,
        in open: OpenPanel,
        rows titled: OpenPanel.TitledRows
    ) throws {
        let panel = CGRect(origin: .zero, size: open.frame.size)
        let rows = rendered.rows.sorted { $0.minY < $1.minY }
        try #require(rows.count == 3, "rows \(rows)")

        for row in rows {
            #expect(abs(row.height - titled.rowHeight) <= rendered.pixel, "row \(row)")
            #expect(row.height >= Layout.minimumHitTarget - rendered.pixel, "row \(row)")
            #expect(Hosted.contains(panel, row, tolerance: rendered.pixel), "row \(row) outside \(panel)")
        }
        for (upper, lower) in zip(rows, rows.dropFirst()) {
            #expect(lower.minY - upper.maxY >= titled.rowGap - 2 * rendered.pixel, "\(upper) above \(lower)")
            #expect(!upper.intersects(lower), "\(upper) meets \(lower)")
        }
        let toggleSwitch = try #require(rendered.switches.first)
        #expect(Hosted.contains(rows[0], toggleSwitch, tolerance: rendered.pixel), "switch \(toggleSwitch)")
    }

    // MARK: The Closed fixture

    @Test("The heading measures the README's 25 pt at L, in the same view the panel draws")
    func headingAtLarge() {
        #expect(Self.paddedHeadingHeight(.large) == Fixture.heading)
    }

    @Test("Closed at L: every control inside the open rectangle and past the close target, each capsule 44 pt and apart")
    func closedAtLarge() throws {
        let open = OpenPanel(Fixture.closedInputs(paddedHeadingHeight: Self.paddedHeadingHeight(.large)))
        let titled = try #require(open.titledRows)
        let layout = Layout(panelWidth: open.frame.width)
        let rendered = try Hosted.render(Self.donePanel(open, dynamicTypeSize: .large), square: open.frame.width)
        let panel = CGRect(origin: .zero, size: open.frame.size)

        #expect(open.mode == .headed)
        try Self.expectRows(rendered, in: open, rows: titled)

        #expect(!rendered.views.isEmpty)
        for (view, frame) in rendered.views {
            #expect(Hosted.contains(panel, frame, tolerance: rendered.pixel), "\(type(of: view)) \(frame) outside \(panel)")
        }
        let closeTarget = layout.artworkHitSpan(panelSide: open.frame.width, isSettledOpen: true).upperBound
        for control in rendered.rows + rendered.switches {
            #expect(control.minX >= closeTarget - rendered.pixel, "control \(control) under \(closeTarget)")
            #expect(control.maxX <= open.frame.width - layout.contentInset + rendered.pixel, "control \(control)")
        }
    }

    @Test(
        "At the Closed row area every title is whole in the done state and the idle long titles too",
        arguments: [
            (title: "Reanalyze", phase: EpisodeAdFreePassPresentationPhase.completed),
            (title: "Show Transcript", phase: .completed),
            (title: "Skip Promos & Ads", phase: .idle),
            (title: "Transcribe", phase: .idle),
            (title: "Transcribe Remotely", phase: .idle)
        ]
    )
    func titlesAreWhole(title: String, phase: EpisodeAdFreePassPresentationPhase) throws {
        let open = OpenPanel(Fixture.closedInputs())
        let rowArea = Layout(panelWidth: open.frame.width).rowAreaWidth
        let measured = NowPlayingSoundLabTitledCapTests.idealRowWidth(title: title, phase: phase)
        #expect(measured <= rowArea, "\(title) row \(measured) in \(rowArea)")
    }

    // MARK: The capsules

    static let textSizes: [DynamicTypeSize] = [.xSmall, .small, .medium, .large, .xLarge, .xxLarge, .xxxLarge]

    @Test("The text sizes tested are every supported non-accessibility size")
    func everyTextSize() {
        #expect(Self.textSizes == DynamicTypeSize.allCases.filter { !$0.isAccessibilitySize })
    }

    @Test(
        "The glass style's vertical chrome: today's row renders its capsule that much past the label's minimum",
        arguments: [DynamicTypeSize.xSmall, .small, .medium, .large, .xLarge, .xxLarge, .xxxLarge]
    )
    func nativeVerticalChrome(size: DynamicTypeSize) throws {
        let row = NowPlayingSoundLabActionRow(
            title: "Reanalyze",
            systemImage: "megaphone",
            tint: .red,
            phase: .completed,
            isEnabled: true,
            isIconOnly: false,
            rowHeight: Layout.compactRowHeight,
            accessibilityValueText: "",
            accessibilityID: "Reanalyze",
            action: {}
        )
        .frame(width: 220, height: 200)
        .environment(\.dynamicTypeSize, size)
        let rendered = try Hosted.render(row, square: 220)
        let capsule = try #require(rendered.rows.first)
        let chrome = (capsule.height - Layout.minimumHitTarget) / 2
        #expect(abs(chrome - Layout.nativeGlassButtonVerticalChrome) <= rendered.pixel, "capsule \(capsule)")
    }

    @Test(
        "Headed at every text size: each styled capsule is the row, holds its label, and stands apart",
        arguments: [DynamicTypeSize.xSmall, .small, .medium, .large, .xLarge, .xxLarge, .xxxLarge]
    )
    func headedCapsules(size: DynamicTypeSize) throws {
        let open = OpenPanel(Fixture.closedInputs(paddedHeadingHeight: Self.paddedHeadingHeight(size)))
        let titled = try #require(open.titledRows)
        #expect(open.mode == .headed)
        let rendered = try Hosted.render(Self.donePanel(open, dynamicTypeSize: size), square: open.frame.width)
        try Self.expectRows(rendered, in: open, rows: titled)
    }

    @Test(
        "Headingless at every text size: the same, in the square's extent",
        arguments: [DynamicTypeSize.xSmall, .small, .medium, .large, .xLarge, .xxLarge, .xxxLarge]
    )
    func headinglessCapsules(size: DynamicTypeSize) throws {
        // A square that holds the rows, under a ceiling that refuses the rise.
        let square = Fixture.closedSquare(side: 170)
        let ceiling = CGRect(x: 0, y: 0, width: 466, height: square.minY - 1 - Layout.openPanelClearance)
        let open = OpenPanel(Fixture.closedInputs(
            square: square,
            occlusions: [ceiling, NowPlayingCardGeometryTests.closedOcclusions[1]],
            paddedHeadingHeight: Self.paddedHeadingHeight(size)
        ))
        let titled = try #require(open.titledRows)
        #expect(open.mode == .headingless)
        let rendered = try Hosted.render(Self.donePanel(open, dynamicTypeSize: size), square: open.frame.width)
        try Self.expectRows(rendered, in: open, rows: titled)
    }

    // MARK: The close target

    @Test("Settled open the close target is the sliver's span over the open height, from the rectangle's leading edge")
    func closeTargetAtTheOpenSize() {
        let side = Fixture.closedSide
        let open = OpenPanel(Fixture.closedInputs())
        let layout = Layout(panelWidth: open.frame.width)
        let target = open.artworkHitFrame(side: side, isSettledOpen: true)

        // In the square's coordinates the rectangle starts left of and above it.
        #expect(Fixture.isNear(target.minX, (side - open.frame.width) / 2))
        #expect(Fixture.isNear(target.minY, side - open.frame.height))
        #expect(Fixture.isNear(target.height, open.frame.height))
        #expect(Fixture.isNear(target.maxY, side))
        #expect(target.width >= Layout.minimumHitTarget)
        #expect(target.width >= layout.artworkExposedWidth)
        #expect(Fixture.isNear(target.width, layout.protectedLeadingSpace))

        #expect(open.artworkHitFrame(side: side, isSettledOpen: false) == CGRect(x: 0, y: 0, width: side, height: side))
    }

    @Test(
        "The legacy value's target is today's span over the square",
        arguments: [154.0, 156.33, 166.92, 214.24, 220.0, 280.8, 337.0]
    )
    func legacyCloseTarget(side: Double) {
        let side = CGFloat(side)
        let span = Layout(panelWidth: side).artworkHitSpan(panelSide: side, isSettledOpen: true)
        let target = OpenPanel.legacy(side: side).artworkHitFrame(side: side, isSettledOpen: true)
        #expect(target == CGRect(x: span.lowerBound, y: 0, width: span.upperBound - span.lowerBound, height: side))
    }

    // MARK: The artwork in a card

    @Observable
    final class Measured {
        var artwork: CGRect?
        var below: CGRect?
    }

    static let cardWidth: CGFloat = 466
    static let cardHeight: CGFloat = 500

    /// The artwork where the Closed card puts it, with a stand-in for the
    /// title block below it, in the card's coordinate space.
    static func closedCard(
        side: CGFloat,
        reveal: Double?,
        direction: LayoutDirection = .leftToRight,
        loadsEpisode: Bool = false,
        measured: Measured
    ) throws -> some View {
        let appModel = OpenCastAppModel(
            localLibraryCacheStore: SQLiteLocalLibraryCacheStore.inMemory(),
            allowsAutomaticFeedRefresh: false
        )
        // With an episode the panel has its third row, the transcript's.
        if loadsEpisode {
            try appModel.playback.load(
                Episode(
                    id: EpisodeID(rawValue: "titled-fit-episode"),
                    podcastID: PodcastID(rawValue: "titled-fit-show"),
                    podcastTitle: "Show",
                    title: "Episode",
                    duration: 600,
                    audioURL: URL(string: "https://example.com/titled-fit.mp3")
                ),
                startPosition: 0
            )
        }
        let context = OpenPanel.CardContext(
            cardGeometry: NowPlayingCardGeometryTests.closed(),
            contentWidth: 418,
            viewport: CGRect(x: 0, y: 0, width: cardWidth, height: cardHeight)
        )
        return VStack(spacing: 12) {
            NowPlayingSoundLabArtwork(
                title: "Show",
                imageURL: nil,
                size: side,
                voiceBoostEnabled: .constant(true),
                voiceBoostControlEnabled: true,
                onAdFreePassAction: {},
                onTranscribeRemotely: {},
                onTranscriptAction: {},
                onAdFreePassBackgroundProbe: {},
                onRequestSoundLabSheet: {},
                isSoundLabInteractionActive: .constant(false),
                isCardDismissDragActive: false,
                openContext: context
            )
            .onGeometryChange(for: CGRect.self) { geometry in
                geometry.frame(in: .named(OpenPanel.CardContext.coordinateSpaceName))
            } action: { frame in
                measured.artwork = frame
            }
            Color.clear
                .frame(height: 40)
                .onGeometryChange(for: CGRect.self) { geometry in
                    geometry.frame(in: .named(OpenPanel.CardContext.coordinateSpaceName))
                } action: { frame in
                    measured.below = frame
                }
        }
        .padding(.top, Fixture.closedTop)
        .padding(.horizontal, 24)
        .frame(width: cardWidth, height: cardHeight, alignment: .top)
        .coordinateSpace(.named(OpenPanel.CardContext.coordinateSpaceName))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(appModel)
        .environment(\.dynamicTypeSize, .large)
        .environment(\.appStoreSoundLabRevealProgress, reveal)
        .environment(\.layoutDirection, direction)
    }

    @Test("Pinned open on the Closed card the panel renders at the resolved rectangle, and the square's neighbours do not move")
    func artworkOnTheClosedCard() throws {
        let side = Fixture.closedSide
        let closed = Measured()
        _ = try Hosted.render(try Self.closedCard(side: side, reveal: nil, measured: closed), square: side)
        let open = Measured()
        let rendered = try Hosted.render(try Self.closedCard(side: side, reveal: 1, measured: open), square: side)

        let closedBelow = try #require(closed.below)
        let openBelow = try #require(open.below)
        #expect(closedBelow == openBelow)
        #expect(Fixture.isNear(closedBelow.minY, Fixture.closedTop + side + 12, within: rendered.pixel))

        // No episode, so two rows: the square's height stands at 282 pt.
        let panel = OpenPanel(Fixture.closedInputs(rowCount: 2))
        let layout = Layout(panelWidth: panel.frame.width)
        let rows = rendered.rows.sorted { $0.minY < $1.minY }
        try #require(rows.count == 2, "rows \(rows)")
        for row in rows {
            #expect(abs(row.minX - (panel.frame.minX + layout.protectedLeadingSpace)) <= 2 * rendered.pixel, "row \(row)")
            #expect(row.maxX > Fixture.closedSquare().maxX, "row \(row) inside the square")
            #expect(abs(row.height - Layout.compactRowHeight) <= rendered.pixel, "row \(row)")
        }
    }

    @Test(
        "The artwork reports the square throughout a pinned reveal",
        arguments: [0.0, 0.25, 0.5, 0.75, 1.0]
    )
    func footprintIsTheSquare(reveal: Double) throws {
        let side = Fixture.closedSide
        let measured = Measured()
        let rendered = try Hosted.render(
            try Self.closedCard(side: side, reveal: reveal, measured: measured),
            square: side
        )
        let frame = try #require(measured.artwork)
        let below = try #require(measured.below)

        #expect(abs(frame.width - side) <= rendered.pixel)
        #expect(abs(frame.height - side) <= rendered.pixel)
        #expect(abs(frame.midX - 233) <= rendered.pixel)
        #expect(abs(frame.minY - Fixture.closedTop) <= rendered.pixel)
        #expect(abs(below.minY - frame.maxY - 12) <= rendered.pixel)
    }

    @Test("With three rows the composed panel takes the taller rectangle and the rows stand where it says, the square unmoved")
    func threeRowsOnTheClosedCard() throws {
        let side = Fixture.closedSide
        let closed = Measured()
        _ = try Hosted.render(try Self.closedCard(side: side, reveal: nil, loadsEpisode: true, measured: closed), square: side)
        let open = Measured()
        let rendered = try Hosted.render(
            try Self.closedCard(side: side, reveal: 1, loadsEpisode: true, measured: open),
            square: side
        )

        let heading = Self.paddedHeadingHeight(.large)
        let panel = OpenPanel(Fixture.closedInputs(paddedHeadingHeight: heading))
        let titled = try #require(panel.titledRows)
        let gap = try #require(titled.headingGap)
        let layout = Layout(panelWidth: panel.frame.width)
        #expect(panel.mode == .headed)
        #expect(panel.frame.height > side)

        // The clip is the visual subtree's: the open rectangle, not the square.
        let clip = try #require(rendered.views.first { $0.view.clipsToBounds && abs($0.frame.width - panel.frame.width) <= rendered.pixel })
        #expect(abs(clip.frame.minX - panel.frame.minX) <= rendered.pixel, "clip \(clip.frame)")
        #expect(abs(clip.frame.minY - panel.frame.minY) <= rendered.pixel, "clip \(clip.frame)")
        #expect(abs(clip.frame.maxY - panel.frame.maxY) <= rendered.pixel, "clip \(clip.frame)")

        let rows = rendered.rows.sorted { $0.minY < $1.minY }
        try #require(rows.count == 3, "rows \(rows)")
        let firstTop = panel.frame.minY + layout.contentInset + titled.verticalRemainder / 2 + heading + gap
        for (index, row) in rows.enumerated() {
            let top = firstTop + CGFloat(index) * (titled.rowHeight + titled.rowGap)
            #expect(abs(row.minY - top) <= 2 * rendered.pixel, "row \(index) \(row) top \(top)")
            // Allow one display pixel for snapped edges, plus 1e-9 pt
            // for floating-point comparison at that boundary.
            #expect(abs(row.height - titled.rowHeight) <= rendered.pixel + 1e-9, "row \(row)")
            #expect(abs(row.minX - (panel.frame.minX + layout.protectedLeadingSpace)) <= 2 * rendered.pixel, "row \(row)")
        }

        #expect(closed.artwork == open.artwork)
        #expect(closed.below == open.below)
    }

    @Test(
        "Every action label's ideal height fits inside the capsule, the style's chrome taken off the row",
        arguments: [DynamicTypeSize.xSmall, .small, .medium, .large, .xLarge, .xxLarge, .xxxLarge]
    )
    func labelsFitTheCapsule(size: DynamicTypeSize) {
        let inner = Layout.compactRowHeight - 2 * Layout.nativeGlassButtonVerticalChrome
        for phase in [EpisodeAdFreePassPresentationPhase.idle, .running] {
            for title in Layout.fixedActionTitles.map(\.title) {
                let row = NowPlayingSoundLabActionRow(
                    title: title,
                    systemImage: "megaphone",
                    tint: .red,
                    phase: phase,
                    isEnabled: true,
                    isIconOnly: false,
                    rowHeight: Layout.compactRowHeight,
                    accessibilityValueText: "",
                    accessibilityID: title,
                    capsuleFitsRow: true,
                    action: {}
                )
                let label = row.labelContent(reduceMotion: false)
                    .environment(\.dynamicTypeSize, size)
                let height = UIHostingController(rootView: label)
                    .sizeThatFits(in: CGSize(width: Self.cardWidth, height: CGFloat.infinity))
                    .height
                #expect(height <= inner, "\(title) \(phase) at \(size): \(height) in \(inner)")
            }
        }
    }

    @Test("The card context hands the resolver the player's geometry, with the stack's span around the square")
    func cardContext() throws {
        let geometry = NowPlayingCardGeometryTests.closed()
        let context = OpenPanel.CardContext(
            cardGeometry: geometry,
            contentWidth: 418,
            viewport: CGRect(x: 0, y: 0, width: 466, height: 678)
        )
        let resolved = context.inputs(
            square: Fixture.closedSquare(),
            displayScale: 3,
            rowCount: 3,
            isAccessibilitySize: false,
            paddedHeadingHeight: Fixture.heading
        )
        let inputs = try #require(resolved)
        #expect(inputs.contentSpan == 24...442)
        #expect(inputs.moreFrame == CGRect(x: 20, y: 62, width: 44, height: 44))
        #expect(inputs.occlusions == geometry.occlusions)
        #expect(inputs.safeTop == 0)
        #expect(inputs.pixelGridOrigin == .zero)
        #expect(OpenPanel(inputs) == OpenPanel(Fixture.closedInputs()))
    }

    @Test("A square no span can be built from gives no inputs, rather than trapping on the range")
    func cardContextRefusesANonFiniteSquare() {
        let context = OpenPanel.CardContext(
            cardGeometry: NowPlayingCardGeometryTests.closed(),
            contentWidth: 418,
            viewport: CGRect(x: 0, y: 0, width: 466, height: 678)
        )
        let squares = [
            CGRect(x: CGFloat.nan, y: 92, width: 156.33, height: 156.33),
            CGRect(x: 100, y: 92, width: CGFloat.nan, height: 156.33),
            CGRect(x: CGFloat.infinity, y: 92, width: 156.33, height: 156.33)
        ]
        for square in squares {
            let inputs = context.inputs(
                square: square,
                displayScale: 3,
                rowCount: 3,
                isAccessibilitySize: false,
                paddedHeadingHeight: Fixture.heading
            )
            #expect(inputs == nil)
        }
    }

    @Test("A named coordinate space reads a right-to-left view from the left, and the context turns that leading-relative")
    func rightToLeftMeasurement() throws {
        let measured = Measured()
        let view = Color.clear
            .frame(width: 100, height: 100)
            .onGeometryChange(for: CGRect.self) { geometry in
                geometry.frame(in: .named(OpenPanel.CardContext.coordinateSpaceName))
            } action: { frame in
                measured.below = frame
            }
            .padding(.leading, 30)
            .frame(width: 400, height: 200, alignment: .leading)
            .coordinateSpace(.named(OpenPanel.CardContext.coordinateSpaceName))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .environment(\.layoutDirection, .rightToLeft)
        _ = try Hosted.render(view, square: 400)
        let frame = try #require(measured.below)
        #expect(frame.minX == 270)

        let context = OpenPanel.CardContext(
            cardGeometry: NowPlayingCardGeometry(
                windowSize: CGSize(width: 400, height: 200),
                safeAreaInsets: EdgeInsets(),
                isRegular: false,
                isAccessibilitySize: false,
                pose: .compact,
                occlusions: []
            ),
            contentWidth: 352,
            viewport: CGRect(x: 0, y: 0, width: 400, height: 200)
        )
        #expect(context.leadingRelative(frame, isRightToLeft: true).minX == 30)
        #expect(context.leadingRelative(frame, isRightToLeft: true).size == frame.size)
        #expect(context.leadingRelative(frame, isRightToLeft: false) == frame)
    }

    @Test("Pinned open on a right-to-left card the rows mirror the left-to-right card's, the sliver at the leading edge")
    func artworkOnARightToLeftCard() throws {
        let side = Fixture.closedSide
        let rendered = try Hosted.render(
            try Self.closedCard(side: side, reveal: 1, direction: .rightToLeft, measured: Measured()),
            square: side
        )
        let panel = OpenPanel(Fixture.closedInputs(rowCount: 2))
        let layout = Layout(panelWidth: panel.frame.width)
        let rows = rendered.rows
        try #require(rows.count == 2, "rows \(rows)")
        // The harness's window is wider than the card, whose leading edge
        // a right-to-left host puts at the window's right.
        let windowWidth: CGFloat = 500
        for row in rows {
            let leadingEdge = windowWidth - row.maxX
            #expect(abs(leadingEdge - (panel.frame.minX + layout.protectedLeadingSpace)) <= 2 * rendered.pixel, "row \(row)")
        }
    }

    @Test("An unlatched drag follows the panel's mode")
    func unlatchedDragFollowsTheMode() {
        #expect(!NowPlayingSoundLabArtwork.readsFootprint(latched: nil, mode: .legacy))
        #expect(NowPlayingSoundLabArtwork.readsFootprint(latched: nil, mode: .headed))
        #expect(NowPlayingSoundLabArtwork.readsFootprint(latched: nil, mode: .headingless))
    }

    @Test("A latched drag keeps its space through a change of mode")
    func latchedDragSurvivesAModeChange() {
        // Legacy to titled stays local.
        #expect(!NowPlayingSoundLabArtwork.readsFootprint(latched: false, mode: .headed))
        #expect(!NowPlayingSoundLabArtwork.readsFootprint(latched: false, mode: .headingless))
        // Titled to legacy stays the footprint.
        #expect(NowPlayingSoundLabArtwork.readsFootprint(latched: true, mode: .legacy))
    }
}
