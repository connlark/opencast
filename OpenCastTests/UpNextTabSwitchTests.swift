import SwiftUI
import Testing
@testable import OpenCast

/// The Up Next Tab switch: which tabs it offers, the step function that
/// moves the tab set between Settings and Up Next, where Settings opens, and
/// what a queue row does in the tab.
@MainActor
@Suite("Up Next Tab switch")
struct UpNextTabSwitchTests {
    private typealias Root = OpenCastTabRootView

    /// Library, Inbox, Downloads and Search: always installed (Playlists
    /// follows its own rule and is left out here).
    private static let fixedTabCount = 4

    private static let eligibilityCells: [(latched: Bool, sizeClass: UserInterfaceSizeClass?)] = [
        (true, .regular), (true, .compact), (true, nil),
        (false, .regular), (false, .compact), (false, nil)
    ]

    @Test("On: Up Next is offered in every scene and Settings in none")
    func switchOnOffers() {
        for cell in Self.eligibilityCells {
            #expect(
                Root.offersUpNextTab(isFoldableScene: cell.latched, horizontalSizeClass: cell.sizeClass, isSwitchOn: true),
                "\(cell)"
            )
        }
        #expect(!Root.offersSettingsTab(isUpNextTabSwitchOn: true))
    }

    @Test("Off: today's rule for Up Next, and Settings everywhere")
    func switchOffOffers() {
        for cell in Self.eligibilityCells {
            #expect(
                Root.offersUpNextTab(isFoldableScene: cell.latched, horizontalSizeClass: cell.sizeClass, isSwitchOn: false)
                    == (cell.latched && cell.sizeClass == .regular),
                "\(cell)"
            )
        }
        #expect(Root.offersSettingsTab(isUpNextTabSwitchOn: false))
    }

    // MARK: The step over its whole input space

    private struct TabState: CustomStringConvertible {
        var isOffered: Bool
        var isShown: Bool

        static let all = [false, true].flatMap { offered in
            [false, true].map { TabState(isOffered: offered, isShown: $0) }
        }

        var description: String {
            "offered \(isOffered) shown \(isShown)"
        }
    }

    @Test("Every input: a withdrawal before an installation, never more tabs than at either end")
    func stepInvariants() {
        let observations: [AppSection?] = AppSection.allCases.map(Optional.some) + [nil]
        var checked = 0
        for upNext in TabState.all {
            for settings in TabState.all {
                for selection in AppSection.allCases {
                    for observed in observations {
                        for pending in [false, true] {
                            checkStep(
                                upNext: upNext,
                                settings: settings,
                                selection: selection,
                                observed: observed,
                                pending: pending
                            )
                            checked += 1
                        }
                    }
                }
            }
        }
        #expect(checked == 16 * AppSection.allCases.count * observations.count * 2)
    }

    private func checkStep(
        upNext: TabState,
        settings: TabState,
        selection: AppSection,
        observed: AppSection?,
        pending: Bool
    ) {
        let context = "upNext \(upNext), settings \(settings), selection \(selection), observed \(String(describing: observed)), pending \(pending)"
        let step = Root.tabSetStep(
            upNext: Root.upNextTabStep(
                isOffered: upNext.isOffered,
                isShown: upNext.isShown,
                selection: selection,
                observedSelection: observed,
                isHandoverPending: pending
            ),
            settings: Root.settingsTabStep(
                isOffered: settings.isOffered,
                isShown: settings.isShown,
                selection: selection,
                observedSelection: observed,
                isHandoverPending: pending
            )
        )
        func count(_ upNextShown: Bool, _ settingsShown: Bool) -> Int {
            Self.fixedTabCount + (upNextShown ? 1 : 0) + (settingsShown ? 1 : 0)
        }
        func isWithdrawalPending(_ tab: TabState) -> Bool {
            tab.isShown && !tab.isOffered
        }
        let before = count(upNext.isShown, settings.isShown)
        let target = count(upNext.isOffered, settings.isOffered)
        var after = (upNext: upNext.isShown, settings: settings.isShown)
        func state(of tab: Root.ManagedTab) -> TabState {
            tab == .upNext ? upNext : settings
        }
        func setShown(_ tab: Root.ManagedTab, _ shown: Bool) {
            if tab == .upNext {
                after.upNext = shown
            } else {
                after.settings = shown
            }
        }

        if pending {
            #expect(step == .none, "\(context)")
        }
        switch step {
        case .none, .awaitSelectionUpdate:
            break
        case .handOverToLibrary(let tab):
            #expect(selection == tab.section, "\(context)")
            #expect(!state(of: tab).isOffered, "\(context)")
        case .install(let tab):
            #expect(!state(of: tab).isShown && state(of: tab).isOffered, "\(context)")
            // Installs only once nothing is waiting to leave.
            #expect(!isWithdrawalPending(upNext) && !isWithdrawalPending(settings), "\(context)")
            setShown(tab, true)
        case .withdraw(let tab):
            #expect(isWithdrawalPending(state(of: tab)), "\(context)")
            #expect(selection != tab.section, "\(context)")
            #expect(selection == observed, "\(context)")
            setShown(tab, false)
        case .replace(let withdrawn, let installed):
            #expect(withdrawn != installed, "\(context)")
            #expect(isWithdrawalPending(state(of: withdrawn)), "\(context)")
            #expect(!state(of: installed).isShown && state(of: installed).isOffered, "\(context)")
            #expect(selection != withdrawn.section, "\(context)")
            #expect(selection == observed, "\(context)")
            setShown(withdrawn, false)
            setShown(installed, true)
        }
        #expect(count(after.upNext, after.settings) <= max(before, target), "\(context)")
        // A selected tab that is leaving, or is gone, goes to the Library first.
        for tab in [Root.ManagedTab.upNext, .settings] where selection == tab.section && !state(of: tab).isOffered && !pending {
            #expect(step == .handOverToLibrary(from: tab), "\(context)")
        }
    }

    // MARK: The flips, step by step

    private struct Update: Equatable {
        var installed: Set<AppSection>
        var selected: AppSection
    }

    /// The tab root's deferred steps as `scheduleTabSetStep` runs them: a
    /// change schedules a step; a step runs later, in its own update, and
    /// decides from the inputs and the selection as they are then; the
    /// selection and handover observers schedule the next.
    private struct Shell {
        var isSwitchOn: Bool
        var latched: Bool
        var sizeClass: UserInterfaceSizeClass?
        var showsUpNext: Bool
        var showsSettings: Bool
        var selected: AppSection
        var observedSelection: AppSection?
        var handoverCount = 0
        var acknowledgedHandoverCount = 0
        var pendingHandoverObservation = false
        var relookPending = false
        var scheduled = 0
        var paths = AppNavigationPaths()
        var updates: [Update] = []

        /// A scene as it starts: the first tab set follows the switch.
        init(isSwitchOn: Bool, latched: Bool = false, sizeClass: UserInterfaceSizeClass? = .compact, selected: AppSection) {
            self.isSwitchOn = isSwitchOn
            self.latched = latched
            self.sizeClass = sizeClass
            self.selected = selected
            observedSelection = selected
            showsUpNext = Root.offersUpNextTab(isFoldableScene: latched, horizontalSizeClass: sizeClass, isSwitchOn: isSwitchOn)
            showsSettings = Root.offersSettingsTab(isUpNextTabSwitchOn: isSwitchOn)
        }

        var isUpNextOffered: Bool {
            Root.offersUpNextTab(isFoldableScene: latched, horizontalSizeClass: sizeClass, isSwitchOn: isSwitchOn)
        }

        var isSettingsOffered: Bool {
            Root.offersSettingsTab(isUpNextTabSwitchOn: isSwitchOn)
        }

        var installed: Set<AppSection> {
            var sections: Set<AppSection> = [.library, .inbox, .downloads, .search]
            if showsUpNext {
                sections.insert(.upNext)
            }
            if showsSettings {
                sections.insert(.settings)
            }
            return sections
        }

        var isConverged: Bool {
            showsUpNext == isUpNextOffered && showsSettings == isSettingsOffered
        }

        mutating func flip(to isOn: Bool) {
            isSwitchOn = isOn
            schedule()
            runScheduled()
        }

        mutating func schedule() {
            if showsUpNext != isUpNextOffered
                || showsSettings != isSettingsOffered
                || (selected == .upNext && !showsUpNext)
                || (selected == .settings && !showsSettings) {
                scheduled += 1
            }
        }

        mutating func runScheduled() {
            repeat {
                runQueued()
                if observedSelection != selected {
                    observedSelection = selected
                    schedule()
                }
                if pendingHandoverObservation {
                    pendingHandoverObservation = false
                    acknowledgedHandoverCount = handoverCount
                    schedule()
                }
                if relookPending {
                    relookPending = false
                    schedule()
                }
            } while scheduled > 0
        }

        private mutating func runQueued() {
            while scheduled > 0 {
                scheduled -= 1
                let isPending = handoverCount != acknowledgedHandoverCount
                let step = Root.tabSetStep(
                    upNext: Root.upNextTabStep(
                        isOffered: isUpNextOffered,
                        isShown: showsUpNext,
                        selection: selected,
                        observedSelection: observedSelection,
                        isHandoverPending: isPending
                    ),
                    settings: Root.settingsTabStep(
                        isOffered: isSettingsOffered,
                        isShown: showsSettings,
                        selection: selected,
                        observedSelection: observedSelection,
                        isHandoverPending: isPending
                    )
                )
                paths = Root.paths(after: step, in: paths)
                switch step {
                case .none:
                    continue
                case .awaitSelectionUpdate:
                    relookPending = true
                    continue
                case .handOverToLibrary:
                    handoverCount += 1
                    selected = .library
                    pendingHandoverObservation = true
                case .install(let tab):
                    set(tab, shown: true)
                case .withdraw(let tab):
                    set(tab, shown: false)
                case .replace(let withdrawn, let installed):
                    set(withdrawn, shown: false)
                    set(installed, shown: true)
                }
                updates.append(Update(installed: installed, selected: selected))
            }
        }

        private mutating func set(_ tab: Root.ManagedTab, shown: Bool) {
            switch tab {
            case .upNext:
                showsUpNext = shown
            case .settings:
                showsSettings = shown
            }
        }
    }

    private static let settingsSet: Set<AppSection> = [.library, .inbox, .downloads, .settings, .search]
    private static let upNextSet: Set<AppSection> = [.library, .upNext, .inbox, .downloads, .search]

    @Test("On from Look & Feel: the Library takes the screen in one update, the tabs swap in the next")
    func onFromLookAndFeel() {
        var shell = Shell(isSwitchOn: false, selected: .settings)
        shell.paths[.settings] = [.settings(.lookAndFeel)]
        shell.paths[.library] = [.podcastDetail(feedURL: "https://example.com/feed.xml")]
        shell.flip(to: true)
        #expect(shell.updates == [
            Update(installed: Self.settingsSet, selected: .library),
            Update(installed: Self.upNextSet, selected: .library)
        ])
        #expect(shell.paths[.library] == [.settings(.hub), .settings(.lookAndFeel)])
        #expect(shell.paths[.settings].isEmpty)
    }

    @Test("On from another tab: one update, the selection stays, Settings' path goes with its tab, every other path stays")
    func onFromAnotherTab() {
        var shell = Shell(isSwitchOn: false, selected: .inbox)
        shell.paths[.library] = [.podcastDetail(feedURL: "https://example.com/feed.xml")]
        shell.paths[.inbox] = [.episodeDetail(id: "inbox-1")]
        shell.paths[.settings] = [.settings(.playback)]
        shell.flip(to: true)
        #expect(shell.updates == [Update(installed: Self.upNextSet, selected: .inbox)])
        #expect(shell.paths[.settings].isEmpty)
        #expect(shell.paths[.library] == [.podcastDetail(feedURL: "https://example.com/feed.xml")])
        #expect(shell.paths[.inbox] == [.episodeDetail(id: "inbox-1")])
    }

    @Test("Off inside the Library: Settings comes back in the update Up Next leaves; the Settings screens stay")
    func offInsideTheLibrary() {
        var shell = Shell(isSwitchOn: true, selected: .library)
        shell.paths[.library] = [.settings(.hub), .settings(.lookAndFeel)]
        shell.flip(to: false)
        #expect(shell.updates == [Update(installed: Self.settingsSet, selected: .library)])
        #expect(shell.paths[.library] == [.settings(.hub), .settings(.lookAndFeel)])
    }

    @Test("Off with Up Next selected: the Library first, then the swap, both paths kept")
    func offWithUpNextSelected() {
        var shell = Shell(isSwitchOn: true, selected: .upNext)
        shell.paths[.upNext] = [.episodeDetail(id: "queued-1")]
        shell.paths[.library] = [.podcastDetail(feedURL: "https://example.com/feed.xml")]
        shell.flip(to: false)
        #expect(shell.updates == [
            Update(installed: Self.upNextSet, selected: .library),
            Update(installed: Self.settingsSet, selected: .library)
        ])
        #expect(shell.paths[.upNext] == [.episodeDetail(id: "queued-1")])
        #expect(shell.paths[.library] == [.podcastDetail(feedURL: "https://example.com/feed.xml")])
    }

    @Test("The Duo's inner display already has Up Next: the switch moves Settings alone")
    func innerDisplay() {
        var shell = Shell(isSwitchOn: false, latched: true, sizeClass: .regular, selected: .inbox)
        #expect(shell.showsUpNext && shell.showsSettings)
        shell.flip(to: true)
        #expect(shell.updates == [Update(installed: Self.upNextSet, selected: .inbox)])
        shell.updates = []
        shell.flip(to: false)
        #expect(shell.updates == [Update(installed: Self.upNextSet.union([.settings]), selected: .inbox)])
    }

    @Test("Closed with the switch on keeps Up Next: no handover")
    func closedWithTheSwitchOn() {
        var shell = Shell(isSwitchOn: true, latched: true, sizeClass: .regular, selected: .upNext)
        shell.sizeClass = .compact
        shell.schedule()
        shell.runScheduled()
        #expect(shell.updates.isEmpty)
        #expect(shell.selected == .upNext)
    }

    @Test(
        "Every flip from every selection: never more tabs than at either end, no selection shares an update with a tab-set change, it ends converged",
        arguments: [false, true]
    )
    func everyFlip(from isOn: Bool) {
        let scenes: [(latched: Bool, sizeClass: UserInterfaceSizeClass?)] = [
            (false, .compact), (false, .regular), (true, .compact), (true, .regular), (false, nil)
        ]
        for scene in scenes {
            let start = Shell(isSwitchOn: isOn, latched: scene.latched, sizeClass: scene.sizeClass, selected: .library)
            for selection in start.installed {
                var shell = Shell(isSwitchOn: isOn, latched: scene.latched, sizeClass: scene.sizeClass, selected: selection)
                let before = shell.installed.count
                shell.flip(to: !isOn)
                let context = "from \(isOn), scene \(scene), selection \(selection)"
                let after = shell.installed.count
                var previous = Update(installed: start.installed, selected: selection)
                for update in shell.updates {
                    #expect(update.installed.count <= max(before, after), "\(context)")
                    #expect(
                        update.installed == previous.installed || update.selected == previous.selected,
                        "\(context): a selection change shared an update with the tab set"
                    )
                    #expect(update.installed.contains(update.selected) || update.selected == previous.selected, "\(context)")
                    previous = update
                }
                #expect(shell.isConverged, "\(context)")
                #expect(shell.installed.contains(shell.selected), "\(context)")
                // On: Up Next and no Settings. Off: Settings, and Up Next only
                // on the inner display.
                #expect(shell.installed.contains(.settings) == isOn, "\(context)")
                #expect(
                    shell.installed.contains(.upNext) == (!isOn || (scene.latched && scene.sizeClass == .regular)),
                    "\(context)"
                )
            }
        }
    }

    @Test("A Settings selection that lands after its withdrawal goes to the Library over the hub")
    func settingsSelectionAfterWithdrawal() {
        var shell = Shell(isSwitchOn: true, selected: .inbox)
        shell.selected = .settings
        shell.schedule()
        shell.runScheduled()
        #expect(shell.selected == .library)
        #expect(shell.paths[.library] == [.settings(.hub)])
        #expect(!shell.showsSettings)
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
        for step in [Root.TabSetStep.withdraw(.settings), .replace(.settings, with: .upNext)] {
            let after = Root.paths(after: step, in: paths)
            #expect(after[.settings].isEmpty, "\(step)")
            #expect(after[.library] == paths[.library], "\(step)")
            #expect(after[.upNext] == paths[.upNext], "\(step)")
        }
        for step in [Root.TabSetStep.withdraw(.upNext), .replace(.upNext, with: .settings), .install(.settings), .none] {
            #expect(Root.paths(after: step, in: paths) == paths, "\(step)")
        }
        // Nothing to drop: a scene with no Settings path is left exactly as it is.
        #expect(Root.paths(after: .withdraw(.settings), in: AppNavigationPaths()) == AppNavigationPaths())
    }

    // MARK: A queue row in the tab (D7)

    @Test("A row plays where the scene has reported no fold, and opens its episode on a foldable scene")
    func queueRowAction() {
        #expect(UpNextRootContent.rowAction(isFoldableScene: false) == .play)
        #expect(UpNextRootContent.rowAction(isFoldableScene: true) == .openEpisode)
    }
}
