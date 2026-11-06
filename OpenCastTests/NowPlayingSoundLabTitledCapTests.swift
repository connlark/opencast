import SwiftUI
import Testing
@testable import OpenCast

/// The titled cap's measured widths, laid out by SwiftUI at the default text
/// size on this runtime: each fixed title in each production state it shows
/// in, the row's own ideal width.
@MainActor
@Suite("Sound Lab titled cap")
struct NowPlayingSoundLabTitledCapTests {
    typealias Layout = NowPlayingSoundLabLayout

    static func idealRowWidth(title: String, phase: EpisodeAdFreePassPresentationPhase) -> CGFloat {
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
            action: {}
        )
        .environment(\.dynamicTypeSize, .large)
        return UIHostingController(rootView: row)
            .sizeThatFits(in: CGSize(width: CGFloat.infinity, height: Layout.compactRowHeight))
            .width
    }

    static func titleWidth(_ title: String) throws -> CGFloat {
        try #require(Layout.fixedActionTitles.first { $0.title == title }).width
    }

    @Test(
        "Each fixed title fits the cap's row area in each state it shows a glyph in, and the measured width is tight",
        arguments: [
            (title: "Skip Promos & Ads", phase: EpisodeAdFreePassPresentationPhase.queued),
            (title: "Skip Promos & Ads", phase: .checking),
            (title: "Skip Promos & Ads", phase: .running),
            (title: "Reanalyze", phase: .completed),
            (title: "Detect on Device", phase: .failed),
            (title: "Resume", phase: .deferred),
            (title: "Resume", phase: .failed),
            (title: "Retry", phase: .failed),
            (title: "Transcribe", phase: .running),
            (title: "Transcribe Remotely", phase: .checking),
            (title: "Transcribe Remotely", phase: .running),
            (title: "Show Transcript", phase: .completed)
        ]
    )
    func glyphStates(title: String, phase: EpisodeAdFreePassPresentationPhase) throws {
        let measured = Self.idealRowWidth(title: title, phase: phase)
        let derived = Layout.glyphActionRowFixedWidth + (try Self.titleWidth(title))
        #expect(measured <= derived, "\(title) \(phase) row \(measured)")
        #expect(measured > derived - 1, "\(title) \(phase) row \(measured)")
        #expect(measured <= Layout.titledRowAreaCap, "\(title) \(phase) row \(measured)")
    }

    @Test(
        "A title in a state with no glyph needs less than the derived row",
        arguments: [
            (title: "Skip Promos & Ads", phase: EpisodeAdFreePassPresentationPhase.idle),
            (title: "Skip Promos & Ads", phase: .unavailable),
            (title: "Transcribe", phase: .idle),
            (title: "Transcribe Remotely", phase: .idle)
        ]
    )
    func glyphlessStates(title: String, phase: EpisodeAdFreePassPresentationPhase) throws {
        let measured = Self.idealRowWidth(title: title, phase: phase)
        #expect(measured <= Layout.glyphActionRowFixedWidth + (try Self.titleWidth(title)), "\(title) row \(measured)")
    }

    @Test("Voice Boost's row fits the cap: the toggle's own threshold is no wider")
    func voiceBoostFitsTheCap() {
        #expect(Layout.iconOnlyRowAreaWidth <= Layout.titledRowAreaCap)
    }

    @Test("The cap is the widest title's row, composed from the constants")
    func capComposition() {
        let parts: [CGFloat] = [
            Layout.controlHorizontalPadding,
            Layout.nativeGlassButtonSideChrome,
            Layout.controlIconDiameter,
            Layout.controlSpacing,
            Layout.controlSpacing,
            Layout.trailingIndicatorMinimumGap,
            Layout.controlSpacing,
            Layout.trailingIndicatorSize,
            Layout.controlHorizontalPadding,
            Layout.nativeGlassButtonSideChrome
        ]
        #expect(Layout.glyphActionRowFixedWidth == parts.reduce(0, +))
        let widest = Layout.fixedActionTitles.map(\.width).max() ?? 0
        #expect(Layout.titledRowAreaCap == Layout.glyphActionRowFixedWidth + widest)
    }

    @Test(
        "The inversion returns the width whose row area it was given, on both sides of the rail's cap at 300 pt",
        arguments: [262.5, 282.0, 299.5, 300.0, 300.5, 310.0, 340.0]
    )
    func inversion(width: Double) {
        let rowArea = Layout(panelWidth: width).rowAreaWidth
        #expect(abs(Layout.panelWidth(forRowArea: rowArea) - width) < 0.0001, "row area \(rowArea)")
    }

    @Test("The two sides of the inversion are the layout's two lines, meeting at 300 pt")
    func inversionKnee() {
        #expect(abs(Layout.panelWidth(forRowArea: 231.5) - 300) < 0.0001)
        #expect(abs(Layout.panelWidth(forRowArea: 220) - 224 / 0.785) < 0.0001)
        #expect(abs(Layout.panelWidth(forRowArea: 240) - 298 / 0.965) < 0.0001)
    }

    @Test("The titled widths: the narrowest holds the toggle, the reference width the cap's row area")
    func titledWidths() {
        #expect(abs(Layout(panelWidth: Layout.titledMinimumWidth).rowAreaWidth - Layout.iconOnlyRowAreaWidth) < 0.0001)
        #expect(abs(Layout(panelWidth: Layout.titledReferenceWidth).rowAreaWidth - Layout.titledRowAreaCap) < 0.0001)
    }
}
