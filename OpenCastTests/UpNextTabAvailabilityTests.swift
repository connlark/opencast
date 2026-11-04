import SwiftUI
import Testing
@testable import OpenCast

/// The Up Next section's eligibility, its deferred insertion and withdrawal,
/// and the queue's entry points.
/// The poses and transitions are fixtures from lane A's probe logs on the
/// iPhone Duo simulator (A1: the size class per pose; A8: a fold passes a
/// compact window), not cases the code knows.
@MainActor
@Suite("Up Next tab availability")
struct UpNextTabAvailabilityTests {
    @Test(
        "Offered only with the fold latch at regular width",
        arguments: [
            (latched: true, sizeClass: UserInterfaceSizeClass?.some(.regular), offered: true),
            (latched: true, sizeClass: .compact, offered: false),
            (latched: true, sizeClass: nil, offered: false),
            (latched: false, sizeClass: .regular, offered: false),
            (latched: false, sizeClass: .compact, offered: false),
            (latched: false, sizeClass: nil, offered: false)
        ]
    )
    func everyCell(latched: Bool, sizeClass: UserInterfaceSizeClass?, offered: Bool) {
        #expect(OpenCastTabRootView.offersUpNextTab(isFoldableScene: latched, horizontalSizeClass: sizeClass) == offered)
    }

    @Test("The inner display's four open poses offer it; Closed, an iPhone and an iPad do not")
    func poses() {
        let cases: [(name: String, latched: Bool, sizeClass: UserInterfaceSizeClass, offered: Bool)] = [
            ("Duo Closed", true, .compact, false),
            ("Duo Book", true, .regular, true),
            ("Duo Open landscape", true, .regular, true),
            ("Duo Open portrait", true, .regular, true),
            ("Duo Laptop", true, .regular, true),
            ("iPhone", false, .compact, false),
            ("iPad full screen", false, .regular, false),
            ("iPad narrow window", false, .compact, false)
        ]
        for item in cases {
            #expect(
                OpenCastTabRootView.offersUpNextTab(isFoldableScene: item.latched, horizontalSizeClass: item.sizeClass)
                    == item.offered,
                "\(item.name)"
            )
        }
    }

    /// The deferred update as `updateUpNextTab` runs it: each reading
    /// records its inputs; when it runs, the update decides from the inputs
    /// as they are THEN. `Reading.runsDeferred` false means the next reading
    /// arrived before the deferred update ran.
    private struct Reading {
        var sizeClass: UserInterfaceSizeClass?
        var latched: Bool
        var runsDeferred = true
    }

    /// The tab root's deferred tab-set steps, driven by its own decision
    /// (`upNextTabStep`): an input change schedules a step; a scheduled step
    /// runs later and decides from the inputs and the selection as they are
    /// then; a selection change schedules the next one.
    private struct Shell {
        var showsTab = false
        var selected = AppSection.inbox
        var recordedSizeClass: UserInterfaceSizeClass?
        var latched = false
        var scheduled = 0
        var handoverCount = 0
        var acknowledgedHandoverCount = 0
        /// The selection as of the last update (`.onChange(of: selectedTab)`).
        var observedSelection: AppSection? = .inbox
        var relookPending = false
        var paths = AppNavigationPaths()
        /// Every update the tab set and the selection went through.
        var updates: [(showsTab: Bool, selected: AppSection)] = []

        var isOffered: Bool {
            OpenCastTabRootView.offersUpNextTab(isFoldableScene: latched, horizontalSizeClass: recordedSizeClass)
        }

        mutating func observe(_ reading: Reading) {
            recordedSizeClass = reading.sizeClass
            latched = reading.latched
            schedule()
            if reading.runsDeferred {
                runScheduled()
            }
        }

        mutating func schedule() {
            if showsTab != isOffered || (selected == .upNext && !showsTab) {
                scheduled += 1
            }
        }

        /// The handover count's observer has not run since a handover.
        var pendingHandoverObservation = false

        /// `.onChange(of: upNextHandoverCount)`, after the update that
        /// carried the handover; it always runs, whatever the selection did.
        mutating func observeHandover() {
            pendingHandoverObservation = false
            acknowledgedHandoverCount = handoverCount
            schedule()
        }

        /// Runs every scheduled step, each in its own update; the selection
        /// observer runs only once the queued steps are done (the worst
        /// case: every queued task runs before it).
        mutating func runScheduled() {
            repeat {
                runQueued()
                // After the update: the observers, then any settle re-look.
                if observedSelection != selected {
                    observedSelection = selected
                    schedule()
                }
                if pendingHandoverObservation {
                    observeHandover()
                }
                if relookPending {
                    relookPending = false
                    schedule()
                }
            } while scheduled > 0
        }

        /// One pass over the queued steps without the observer (tests that
        /// interleave a user action before it runs).
        mutating func runQueuedForTest() {
            runQueued()
        }

        private mutating func runQueued() {
            while scheduled > 0 {
                scheduled -= 1
                switch OpenCastTabRootView.upNextTabStep(
                    isOffered: isOffered,
                    isShown: showsTab,
                    selection: selected,
                    observedSelection: observedSelection,
                    isHandoverPending: handoverCount != acknowledgedHandoverCount
                ) {
                case .none:
                    continue
                case .awaitSelectionUpdate:
                    relookPending = true
                case .handOverToLibrary:
                    handoverCount += 1
                    selected = .library
                    updates.append((showsTab, selected))
                    pendingHandoverObservation = true
                case .install:
                    showsTab = true
                    updates.append((showsTab, selected))
                case .withdraw:
                    showsTab = false
                    updates.append((showsTab, selected))
                }
            }
        }
    }

    @Test("A late latch inserts the tab without a size-class change")
    func lateLatch() {
        var shell = Shell()
        shell.observe(Reading(sizeClass: .regular, latched: false))
        #expect(!shell.showsTab)
        shell.observe(Reading(sizeClass: .regular, latched: true))
        #expect(shell.showsTab)
    }

    @Test("A deferred update decides from the inputs when it runs, never the ones that scheduled it")
    func deferredReadsCurrentInputs() {
        var shell = Shell()
        shell.observe(Reading(sizeClass: .regular, latched: true))
        #expect(shell.showsTab)
        // Folding shut schedules a withdrawal; the window reads regular again
        // before the update runs (a transient), so the tab stays.
        shell.observe(Reading(sizeClass: .compact, latched: true, runsDeferred: false))
        shell.observe(Reading(sizeClass: .regular, latched: true, runsDeferred: false))
        shell.runScheduled()
        #expect(shell.showsTab)
    }

    @Test("Withdrawn while selected (Closed): Library first, both paths kept, no reselection on reopening")
    func withdrawalWhileSelected() {
        var shell = Shell()
        shell.observe(Reading(sizeClass: .regular, latched: true))
        shell.selected = .upNext
        shell.paths[.upNext] = [.episodeDetail(id: "queued-1")]
        shell.paths[.library] = [.podcastDetail(feedURL: "https://example.com/feed.xml")]
        // Book → Closed, through A8's compact window with no rail.
        shell.updates = []
        shell.observe(Reading(sizeClass: .compact, latched: true))
        #expect(!shell.showsTab)
        #expect(shell.selected == .library)
        // The Library is selected in one update and the tab goes in the next:
        // never removed while selected, never both at once.
        #expect(shell.updates.map(\.showsTab) == [true, false])
        #expect(shell.updates.map(\.selected) == [.library, .library])
        #expect(shell.paths[.upNext] == [.episodeDetail(id: "queued-1")])
        #expect(shell.paths[.library] == [.podcastDetail(feedURL: "https://example.com/feed.xml")])
        // Reopening offers the tab again and leaves the Library selected.
        shell.observe(Reading(sizeClass: .regular, latched: true))
        #expect(shell.showsTab)
        #expect(shell.selected == .library)
    }

    @Test("Queued duplicate steps cannot withdraw a selected tab in the handover's update")
    func duplicateQueuedSteps() {
        var shell = Shell()
        shell.observe(Reading(sizeClass: .regular, latched: true))
        shell.selected = .upNext
        shell.updates = []
        // Several notifications queue steps before any runs.
        shell.observe(Reading(sizeClass: .compact, latched: true, runsDeferred: false))
        shell.schedule()
        shell.schedule()
        #expect(shell.scheduled == 3)
        shell.runScheduled()
        #expect(shell.updates.map(\.showsTab) == [true, false])
        #expect(shell.updates.map(\.selected) == [.library, .library])
        #expect(!shell.showsTab)
    }

    @Test("Up Next reselected before the handover is observed: another handover, then the withdrawal")
    func reselectedDuringHandover() {
        var shell = Shell()
        shell.observe(Reading(sizeClass: .regular, latched: true))
        shell.selected = .upNext
        shell.observe(Reading(sizeClass: .compact, latched: true, runsDeferred: false))
        // The first queued step hands over; Up Next is selected again
        // before the handover's observer runs.
        shell.updates = []
        var once = shell
        once.scheduled = 1
        once.runQueuedForTest()
        #expect(once.selected == .library)
        once.selected = .upNext
        once.runScheduled()
        #expect(!once.showsTab)
        #expect(once.selected == .library)
        #expect(once.updates.map(\.showsTab) == [true, true, false])
    }

    @Test("Another writer's selection waits for its update before the withdrawal")
    func otherSelectionWriter() {
        var shell = Shell()
        shell.observe(Reading(sizeClass: .regular, latched: true))
        shell.selected = .upNext
        shell.observedSelection = .upNext
        shell.observe(Reading(sizeClass: .compact, latched: true, runsDeferred: false))
        // The Search command writes the selection before the step runs.
        shell.selected = .search
        shell.updates = []
        var once = shell
        once.runQueuedForTest()
        // Not withdrawn in the update that carries `.search`.
        #expect(once.showsTab)
        #expect(once.updates.isEmpty)
        once.runScheduled()
        #expect(!once.showsTab)
        #expect(once.selected == .search)
        #expect(once.updates.map(\.showsTab) == [false])
    }

    @Test("A selection of Up Next that lands after its withdrawal is handed to the Library")
    func selectionAfterWithdrawal() {
        var shell = Shell()
        shell.observe(Reading(sizeClass: .regular, latched: true))
        shell.selected = .library
        shell.observedSelection = .library
        shell.observe(Reading(sizeClass: .compact, latched: true))
        #expect(!shell.showsTab)
        // The still-rendered Up Next control's queued selection lands now.
        shell.selected = .upNext
        shell.runScheduled()
        #expect(shell.selected == .library)
        #expect(!shell.showsTab)
    }

    @Test("Open-to-open readings keep the tab and the selection")
    func openToOpen() {
        var shell = Shell()
        shell.observe(Reading(sizeClass: .regular, latched: true))
        shell.selected = .upNext
        // Book → Laptop and Open landscape → Open portrait read regular
        // throughout (A1); any compact reading in between is logged and, if
        // it hands over, is STOP 2.
        for _ in 0..<4 {
            shell.observe(Reading(sizeClass: .regular, latched: true))
        }
        #expect(shell.showsTab)
        #expect(shell.selected == .upNext)
    }

    @Test("One step toward eligibility from the current inputs and selection", arguments: AppSection.allCases)
    func steps(selection: AppSection) {
        func step(_ offered: Bool, _ shown: Bool, pending: Bool = false, observed: AppSection?? = .none) -> OpenCastTabRootView.UpNextTabStep {
            OpenCastTabRootView.upNextTabStep(
                isOffered: offered,
                isShown: shown,
                selection: selection,
                observedSelection: observed ?? selection,
                isHandoverPending: pending
            )
        }
        #expect(step(true, true) == .none)
        #expect(step(true, false) == .install)
        let withdrawal: OpenCastTabRootView.UpNextTabStep = selection == .upNext ? .handOverToLibrary : .withdraw
        #expect(step(false, true) == withdrawal)
        // Up Next selected with no tab and none offered: handed over.
        #expect(step(false, false) == (selection == .upNext ? .handOverToLibrary : .none))
        // A selection that has not landed: a withdrawal waits for it.
        if selection != .upNext {
            #expect(step(false, true, observed: .some(.upNext)) == .awaitSelectionUpdate)
            #expect(step(false, true, observed: .some(nil)) == .awaitSelectionUpdate)
        }
        // While a handover awaits its observation, no step at all.
        #expect(step(false, true, pending: true) == .none)
        #expect(step(true, false, pending: true) == .none)
    }

    @Test("A withdrawal of an unselected tab leaves the selection")
    func withdrawalUnselected() {
        var shell = Shell()
        shell.observe(Reading(sizeClass: .regular, latched: true))
        shell.selected = .downloads
        shell.observe(Reading(sizeClass: .compact, latched: true))
        #expect(!shell.showsTab)
        #expect(shell.selected == .downloads)
    }

    @Test("The queue's entry points select the installed, eligible tab, else present the sheet")
    func queueOpening() {
        #expect(OpenCastTabRootView.upNextOpening(isTabInstalled: true, isTabOffered: true) == .selectTab)
        #expect(OpenCastTabRootView.upNextOpening(isTabInstalled: true, isTabOffered: false) == .presentSheet)
        #expect(OpenCastTabRootView.upNextOpening(isTabInstalled: false, isTabOffered: true) == .presentSheet)
        #expect(OpenCastTabRootView.upNextOpening(isTabInstalled: false, isTabOffered: false) == .presentSheet)
    }

    @Test("A queue row in the tab opens its episode: the detail's root in the split, a push in the stack")
    func queueRowActivation() {
        let route = UpNextRootContent.route(forQueuedEpisode: "queued-2")
        #expect(route == .episodeDetail(id: "queued-2"))
        #expect(TwoPaneRootPath.openingFromRoot(route, in: [.episodeDetail(id: "queued-1"), .episodeTranscript(id: "queued-1")], container: .split) == [route])
        #expect(TwoPaneRootPath.openingFromRoot(route, in: [], container: .stack) == [route])
    }
}
