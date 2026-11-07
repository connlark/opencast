import Testing
import UIKit
@testable import OpenCast

/// The tab glyphs (D19), one set on every device. A tab bar draws a symbol's
/// fill variant where it has one, so the six that do are pinned too; the search
/// role's magnifier has none and is drawn as a line.
@MainActor
@Suite("App section symbols")
struct AppSectionSymbolTests {
    private static let symbols: [AppSection: String] = [
        .library: "books.vertical",
        .playlists: "list.bullet.rectangle",
        .upNext: "play.square.stack",
        .inbox: "tray",
        .downloads: "square.and.arrow.down",
        .settings: "gearshape",
        .search: "magnifyingglass"
    ]

    @Test("Every section has its chosen symbol", arguments: AppSection.allCases)
    func mapping(section: AppSection) {
        #expect(section.systemImage == Self.symbols[section])
    }

    @Test("Every chosen symbol exists", arguments: AppSection.allCases)
    func availability(section: AppSection) {
        #expect(UIImage(systemName: section.systemImage) != nil)
    }

    @Test(
        "The fill variant a tab bar selects exists",
        arguments: [AppSection.library, .playlists, .upNext, .inbox, .downloads, .settings]
    )
    func fillVariants(section: AppSection) {
        #expect(UIImage(systemName: "\(section.systemImage).fill") != nil)
    }
}
