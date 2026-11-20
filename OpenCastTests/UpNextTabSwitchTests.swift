import SwiftUI
import Testing
@testable import OpenCast

@MainActor
@Suite("Up Next Tab switch")
struct UpNextTabSwitchTests {
    private typealias Root = OpenCastTabRootView

    // MARK: The flips, step by step

    @Test("A flip hands a selected leaving tab to the Library first, and a withdrawal and an installation share one update")
    func flipSteps() {
        func step(
            upNext: (offered: Bool, shown: Bool),
            settings: (offered: Bool, shown: Bool),
            selection: AppSection,
            observed: AppSection?,
            pending: Bool = false
        ) -> Root.TabSetStep {
            Root.tabSetStep(
                upNext: Root.upNextTabStep(
                    isOffered: upNext.offered,
                    isShown: upNext.shown,
                    selection: selection,
                    observedSelection: observed,
                    isHandoverPending: pending
                ),
                settings: Root.settingsTabStep(
                    isOffered: settings.offered,
                    isShown: settings.shown,
                    selection: selection,
                    observedSelection: observed,
                    isHandoverPending: pending
                )
            )
        }

        // On from Look & Feel.
        #expect(step(upNext: (true, false), settings: (false, true), selection: .settings, observed: .settings)
            == .handOverToLibrary(from: .settings))
        #expect(step(upNext: (true, false), settings: (false, true), selection: .library, observed: .settings, pending: true)
            == .none)
        #expect(step(upNext: (true, false), settings: (false, true), selection: .library, observed: .library)
            == .replace(.settings, with: .upNext))
        // Off with Up Next selected, then another writer's selection that has not landed yet.
        #expect(step(upNext: (false, true), settings: (true, false), selection: .upNext, observed: .upNext)
            == .handOverToLibrary(from: .upNext))
        #expect(step(upNext: (false, true), settings: (true, false), selection: .search, observed: .upNext)
            == .awaitSelectionUpdate)
        #expect(step(upNext: (false, true), settings: (true, false), selection: .search, observed: .search)
            == .replace(.upNext, with: .settings))
        // A Settings selection that lands after its tab is gone.
        #expect(step(upNext: (true, true), settings: (false, false), selection: .settings, observed: .settings)
            == .handOverToLibrary(from: .settings))
        // The fold alone, with the switch off.
        #expect(step(upNext: (false, true), settings: (true, true), selection: .downloads, observed: .downloads)
            == .withdraw(.upNext))
        #expect(step(upNext: (true, false), settings: (true, true), selection: .downloads, observed: .downloads)
            == .install(.upNext))
        // The switch alone, with the fold keeping Up Next.
        #expect(step(upNext: (true, true), settings: (false, true), selection: .inbox, observed: .inbox)
            == .withdraw(.settings))
        #expect(step(upNext: (true, true), settings: (true, false), selection: .inbox, observed: .inbox)
            == .install(.settings))
    }

    // MARK: Where Settings opens

    @Test("A Settings screen opens on the Settings tab, or with the switch on in the Library over the hub")
    func settingsOpening() {
        #expect(SettingsOpening.opening(.aiServices, showsUpNextTab: false)
            == SettingsOpening(section: .settings, path: [.settings(.aiServices)]))
        #expect(SettingsOpening.opening(.aiServices, showsUpNextTab: true)
            == SettingsOpening(section: .library, path: [.settings(.hub), .settings(.aiServices)]))
        #expect(SettingsOpening.libraryPath(continuing: []) == [.settings(.hub)])
    }

    @Test("Handing Settings to the Library moves its path over the hub; handing Up Next over moves no path")
    func handoverPaths() {
        var paths = AppNavigationPaths()
        paths[.settings] = [.settings(.lookAndFeel), .settings(.appIcon)]
        paths[.library] = [.podcastDetail(feedURL: "https://example.com/feed.xml")]
        paths[.upNext] = [.episodeDetail(id: "queued-1")]
        let settingsHandedOver = Root.paths(after: .handOverToLibrary(from: .settings), in: paths)
        #expect(settingsHandedOver[.library] == [.settings(.hub), .settings(.lookAndFeel), .settings(.appIcon)])
        #expect(settingsHandedOver[.settings].isEmpty)
        #expect(settingsHandedOver[.upNext] == [.episodeDetail(id: "queued-1")])
        #expect(Root.paths(after: .handOverToLibrary(from: .upNext), in: paths) == paths)
    }

    @Test("A withdrawn Settings tab never keeps a path; Up Next keeps its own through a withdrawal")
    func withdrawalPaths() {
        var paths = AppNavigationPaths()
        paths[.settings] = [.settings(.playback)]
        paths[.library] = [.podcastDetail(feedURL: "https://example.com/feed.xml")]
        paths[.upNext] = [.episodeDetail(id: "queued-1")]

        let afterWithdrawal = Root.paths(after: .withdraw(.settings), in: paths)

        #expect(afterWithdrawal[.settings].isEmpty)
        #expect(afterWithdrawal[.library] == [.podcastDetail(feedURL: "https://example.com/feed.xml")])
        #expect(afterWithdrawal[.upNext] == [.episodeDetail(id: "queued-1")])
        #expect(Root.paths(after: .replace(.settings, with: .upNext), in: paths)[.settings].isEmpty)
        #expect(Root.paths(after: .withdraw(.upNext), in: paths) == paths)
        #expect(Root.paths(after: .replace(.upNext, with: .settings), in: paths) == paths)
    }
}
