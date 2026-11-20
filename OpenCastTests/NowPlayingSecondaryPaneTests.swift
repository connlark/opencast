import CoreGraphics
import Testing
@testable import OpenCast

@Suite("Now Playing secondary pane")
struct NowPlayingSecondaryPaneTests {
    static let bookBand = CGRect(x: 455.5, y: 0, width: 40, height: 669)
    static let laptopBand = CGRect(x: 0, y: 455.5, width: 669, height: 40)

    static func presentation(
        _ arrangement: NowPlayingArrangement,
        _ selection: NowPlayingSecondaryPane,
        expanded: Bool = false,
        sheet: PlayerUtilitySheet? = nil
    ) -> NowPlayingSecondaryPanePresentation {
        NowPlayingSecondaryPanePresentation(
            arrangement: arrangement,
            selection: selection,
            isDisclosureExpanded: expanded,
            presentedSheet: sheet
        )
    }

    @Test("The disclosure row collapses and expands without touching the selection")
    func disclosureCollapse() {
        let collapsed = Self.presentation(.single(band: Self.laptopBand), .transcript)
        #expect(collapsed.style == .disclosure)
        #expect(!collapsed.isExpanded)
        #expect(!collapsed.showsPane)
        #expect(collapsed.content == nil)
        #expect(collapsed.selection == .transcript)

        let expanded = Self.presentation(.single(band: Self.laptopBand), .transcript, expanded: true)
        #expect(expanded.isExpanded)
        #expect(expanded.showsPane)
        #expect(expanded.content == .transcript)
        #expect(expanded.selection == .transcript)
    }

    @Test("Compact and non-foldable cards show no pane and no row, whatever the expansion state")
    func cardHasNoPane() {
        for expanded in [false, true] {
            let card = Self.presentation(.card, .showNotes, expanded: expanded)
            #expect(card.style == .entryPointsOnly)
            #expect(!card.showsPane)
            #expect(!card.isExpanded)
            #expect(card.content == nil)
            #expect(card.selection == .showNotes)
        }
    }

    @Test("While an open sheet shows the selected destination, the inline copy is suppressed; another sheet leaves it")
    func duplicateSuppression() {
        let duplicated = Self.presentation(.split(band: Self.bookBand), .upNext, sheet: .upNext)
        #expect(duplicated.showsPane)
        #expect(duplicated.content == nil)
        #expect(Self.presentation(.split(band: nil), .chapters, sheet: .chapters).content == nil)
        #expect(Self.presentation(.single(band: nil), .transcript, expanded: true, sheet: .transcript).content == nil)
        #expect(Self.presentation(.split(band: nil), .upNext, sheet: .chapters).content == .upNext)
        #expect(Self.presentation(.split(band: nil), .upNext, sheet: .speed).content == .upNext)
        #expect(Self.presentation(.split(band: nil), .showNotes, sheet: .notes).content == .showNotes)
        #expect(Self.presentation(.split(band: Self.bookBand), .upNext, sheet: nil).content == .upNext)
    }
}
