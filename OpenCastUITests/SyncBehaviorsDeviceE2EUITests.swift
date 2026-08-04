import XCTest

/// Two-device CloudKit exercise driver (opt-in, physical devices).
///
/// Each `testStep…` method is one device-side step; the external orchestrator
/// runs them one at a time, alternating devices. The subscription and playback
/// exercise follows this sequence:
///
///   A00 → A01 → B01 → A02 → B02 → A03 → B03 → A04 → B04 → A05 → B05 →
///   A06 → B06 → A07 → B07
///
/// The episode-identity exercise drives the grafted feed served by
/// `Server/ExerciseFeedWorker`, whose GUID generation the orchestrator flips
/// between steps:
///
///   C01 → D01 → [feed flips v1→v2] → C02 → D02 → D03 → C03 → D04 → C04
///
/// Device A performs the mutations (subscribe, play/pause, unsubscribe
/// variants, manual clear, identity merge); device B only observes
/// convergence. The dedicated fixture feeds keep the exercise off the
/// almanac fixtures other suites depend on. Library membership is driven
/// through subscription rows and swipe actions; played state is read and
/// written through search-result row context menus, which stay stable while
/// the freshly synced feed's navigation pushes can get pruned. Set
/// `TEST_RUNNER_OPENCAST_SYNC_E2E=1` to run.
final class SyncBehaviorsDeviceE2EUITests: XCTestCase {
    private static let optInEnvironmentKey = "OPENCAST_SYNC_E2E"
    private static let syncTimeout: TimeInterval = 420

    /// The feed a step operates on. The A/B steps drive the seed podcast; the
    /// C/D steps drive the grafted podcast, whose GUIDs
    /// flip between generations mid-exercise to reproduce the changed-ID
    /// legacy state the identity reconciliation and merge sweep repair.
    /// Playback episodes are short ones: fresh subscriptions default
    /// auto-detect off, so playing them cannot trigger the almanac's
    /// standing ad-detection pass or its dialogs.
    private struct ExerciseFeed {
        let urlString: String
        let historyEpisode: String
        let playbackEpisode: String

        var rowIdentifier: String { "subscription-row-\(urlString)" }

        static let seed = ExerciseFeed(
            urlString: "https://feeds.example.com/sync-e2e.xml",
            historyEpisode: "Seed One",
            playbackEpisode: "Root Three"
        )
        static let graft = ExerciseFeed(
            urlString: "https://graft.example.com/feed.xml",
            historyEpisode: "Graft One",
            playbackEpisode: "Bridge Three"
        )
    }

    private var feed: ExerciseFeed = .seed

    override func setUpWithError() throws {
        continueAfterFailure = false
        addUIInterruptionMonitor(withDescription: "paste permission") { alert in
            MainActor.assumeIsolated {
                let deny = alert.buttons["Don't Allow Paste"]
                if deny.exists {
                    deny.tap()
                    return true
                }
                return false
            }
        }
        addUIInterruptionMonitor(withDescription: "notification permission") { alert in
            MainActor.assumeIsolated {
                let allow = alert.buttons["Allow"]
                if allow.exists {
                    allow.tap()
                    return true
                }
                return false
            }
        }
    }

    // MARK: - Device A steps (mutations)

    /// A system picture-in-picture window floating over the toolbar swallows
    /// taps on the app's top-of-screen controls. Stash it off the right edge
    /// (harmless quick swipe when no PiP is up) before driving the app.
    @MainActor
    func testStepA00StashSystemPiPIfPresent() throws {
        try skipUnlessSyncE2E()
        stashSystemPiPIfPresent()

        // Environment prep: title-keyed episode reads later in the flow are
        // ambiguous while a legacy raw-URL variant of the seed feed carries
        // twin episodes, so retire any such subscription up front.
        let app = launchApp()
        removeLegacySeedVariantRowsIfPresent(in: app)
    }

    @MainActor
    private func stashSystemPiPIfPresent() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let start = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.18))
        let end = springboard.coordinate(withNormalizedOffset: CGVector(dx: 1.1, dy: 0.5))
        start.press(forDuration: 0.3, thenDragTo: end)
        sleep(2)
    }

    @MainActor
    func testStepA01SubscribeAndSeedHistory() throws {
        try skipUnlessSyncE2E()
        let app = launchApp()

        removeExercisePodcastIfPresent(in: app)
        subscribeToExerciseFeed(in: app)
        playAndPausePlaybackEpisode(in: app)
        setHistoryEpisodePlayed(true, in: app)
        XCTAssertTrue(
            historyEpisodeIsPlayed(in: app),
            "history episode should read as played after marking"
        )
        attachAppScreenshot(of: app, named: "A01-subscribed-history-seeded")
    }

    @MainActor
    func testStepA02UnsubscribeKeepingHistory() throws {
        try skipUnlessSyncE2E()
        let app = launchApp()

        playAndPausePlaybackEpisode(in: app)
        unsubscribeExercisePodcast(clearingHistory: false, in: app)
        assertExercisePodcastAbsent(in: app)
        attachAppScreenshot(of: app, named: "A02-unsubscribed-default")
    }

    @MainActor
    func testStepA03ResubscribeVerifyHistoryKept() throws {
        try skipUnlessSyncE2E()
        let app = launchApp()

        subscribeToExerciseFeed(in: app)
        XCTAssertTrue(
            waitForHistoryEpisodePlayed(true, in: app),
            "history should survive default unsubscribe + resubscribe on A"
        )
        attachAppScreenshot(of: app, named: "A03-resubscribed-history-kept")
    }

    @MainActor
    func testStepA04UnsubscribeClearingHistory() throws {
        try skipUnlessSyncE2E()
        let app = launchApp()

        playAndPausePlaybackEpisode(in: app)
        unsubscribeExercisePodcast(clearingHistory: true, in: app)
        assertExercisePodcastAbsent(in: app)
        attachAppScreenshot(of: app, named: "A04-unsubscribed-clear-history")
    }

    @MainActor
    func testStepA05ResubscribeVerifyHistoryCleared() throws {
        try skipUnlessSyncE2E()
        let app = launchApp()

        subscribeToExerciseFeed(in: app)
        // Convergence, not an instant read: a not-yet-imported CloudKit copy
        // may flash into view until tombstone enforcement deletes it.
        XCTAssertTrue(
            waitForHistoryEpisodePlayed(false, in: app),
            "Unsubscribe & Clear History should converge to no played state on A"
        )
        attachAppScreenshot(of: app, named: "A05-resubscribed-history-cleared")
    }

    @MainActor
    func testStepA06SeedUnfollowedHistoryAndManualClear() throws {
        try skipUnlessSyncE2E()
        let app = launchApp()

        setHistoryEpisodePlayed(true, in: app)
        XCTAssertTrue(historyEpisodeIsPlayed(in: app), "played marker should stick before unsubscribe")
        unsubscribeExercisePodcast(clearingHistory: false, in: app)
        assertExercisePodcastAbsent(in: app)

        clearHistoryForUnfollowedShows(in: app)

        subscribeToExerciseFeed(in: app)
        XCTAssertTrue(
            waitForHistoryEpisodePlayed(false, in: app),
            "manual clear should converge to no played state on A"
        )
        attachAppScreenshot(of: app, named: "A06-manual-clear-applied")
    }

    @MainActor
    func testStepA07Cleanup() throws {
        try skipUnlessSyncE2E()
        let app = launchApp()

        removeExercisePodcastIfPresent(in: app)
        removeLegacySeedVariantRowsIfPresent(in: app)
        assertExercisePodcastAbsent(in: app)
        attachAppScreenshot(of: app, named: "A07-cleanup")
    }

    // MARK: - Device B steps (observation)

    @MainActor
    func testStepB01VerifySubscriptionAndHistoryArrived() throws {
        try skipUnlessSyncE2E()
        let app = launchApp()

        waitForExercisePodcast(present: true, in: app)
        XCTAssertTrue(
            waitForHistoryEpisodePlayed(true, in: app),
            "played history should sync to device B"
        )
        attachAppScreenshot(of: app, named: "B01-subscription-and-history-arrived")
    }

    @MainActor
    func testStepB02VerifyUnsubscribeArrived() throws {
        try skipUnlessSyncE2E()
        let app = launchApp()

        waitForExercisePodcast(present: false, in: app)
        attachAppScreenshot(of: app, named: "B02-unsubscribe-arrived")
    }

    @MainActor
    func testStepB03VerifyHistoryVisibleAfterResubscribe() throws {
        try skipUnlessSyncE2E()
        let app = launchApp()

        waitForExercisePodcast(present: true, in: app)
        XCTAssertTrue(
            waitForHistoryEpisodePlayed(true, in: app),
            "history should be visible on device B after the default-unsubscribe cycle"
        )
        attachAppScreenshot(of: app, named: "B03-history-visible")
    }

    @MainActor
    func testStepB04VerifyClearHistoryUnsubscribeArrived() throws {
        try skipUnlessSyncE2E()
        let app = launchApp()

        waitForExercisePodcast(present: false, in: app)
        attachAppScreenshot(of: app, named: "B04-clear-unsubscribe-arrived")
    }

    @MainActor
    func testStepB05VerifyHistoryGone() throws {
        try skipUnlessSyncE2E()
        let app = launchApp()

        waitForExercisePodcast(present: true, in: app)
        XCTAssertTrue(
            waitForHistoryEpisodePlayed(false, in: app),
            "Unsubscribe & Clear History should converge to no played state on B"
        )
        attachAppScreenshot(of: app, named: "B05-history-gone")
    }

    @MainActor
    func testStepB06VerifyManualClearConverged() throws {
        try skipUnlessSyncE2E()
        let app = launchApp()

        waitForExercisePodcast(present: true, in: app)
        XCTAssertTrue(
            waitForHistoryEpisodePlayed(false, in: app),
            "manual clear on A should converge to no played state on B"
        )
        attachAppScreenshot(of: app, named: "B06-manual-clear-converged")
    }

    @MainActor
    func testStepB07VerifyCleanupArrived() throws {
        try skipUnlessSyncE2E()
        let app = launchApp()

        waitForExercisePodcast(present: false, in: app)
        attachAppScreenshot(of: app, named: "B07-cleanup-arrived")
    }

    // MARK: - Phase-7 identity exercise: device A steps (mutations)

    /// C01: with the grafted feed serving its legacy GUID generation (v1),
    /// subscribe, play the playback episode briefly, and mark the history
    /// episode played — synced progress lands under the legacy episode IDs.
    @MainActor
    func testStepC01SubscribeGraftAndSeedLegacyHistory() throws {
        try skipUnlessSyncE2E()
        feed = .graft
        stashSystemPiPIfPresent()
        let app = launchApp()

        removeExercisePodcastIfPresent(in: app)
        subscribeToExerciseFeed(in: app)
        playAndPausePlaybackEpisode(in: app)
        setHistoryEpisodePlayed(true, in: app)
        XCTAssertTrue(
            historyEpisodeIsPlayed(in: app),
            "history episode should read as played under the legacy GUIDs"
        )
        attachAppScreenshot(of: app, named: "C01-graft-legacy-history-seeded")
    }

    /// C02: the orchestrator has flipped the feed to its modern GUID
    /// generation (v2), so every cached episode's ID is now stale. Run the
    /// diagnostics "Merge Duplicate Episodes" sweep and verify the history
    /// episode's played state survives the re-key on this device without
    /// duplicating the row.
    @MainActor
    func testStepC02MergeDuplicateEpisodes() throws {
        try skipUnlessSyncE2E()
        feed = .graft
        let app = launchApp()

        openDiagnostics(in: app)
        runMergeDuplicateEpisodes(in: app)
        attachAppScreenshot(of: app, named: "C02-merge-result")

        XCTAssertTrue(
            waitForHistoryEpisodePlayed(true, in: app),
            "played history should survive the identity merge on A"
        )
        assertSingleEpisodeSearchRow(for: feed.historyEpisode, in: app)
        attachAppScreenshot(of: app, named: "C02-history-survives-merge")
    }

    /// C03: retire the grafted podcast with cleared history so its
    /// tombstones leave CloudKit clean for future exercise runs.
    @MainActor
    func testStepC03CleanupGraft() throws {
        try skipUnlessSyncE2E()
        feed = .graft
        let app = launchApp()

        removeExercisePodcastIfPresent(in: app)
        assertExercisePodcastAbsent(in: app)
        attachAppScreenshot(of: app, named: "C03-graft-cleanup")
    }

    /// C04: the notification feed-health leg — run the diagnostics live
    /// sync against the notifications worker and verify the response was
    /// accepted; the per-feed health rows underneath render only when the
    /// response's health field decoded and persisted end to end.
    @MainActor
    func testStepC04NotificationHealthSyncEvidence() throws {
        try skipUnlessSyncE2E()
        let app = launchApp()

        openDiagnostics(in: app)
        let syncButton = app.buttons["Sync Notification Subscriptions"].firstMatch
        var swipes = 0
        while !syncButton.exists && swipes < 14 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(
            syncButton.waitForExistence(timeout: 10),
            "notification sync diagnostic should exist"
        )
        syncButton.tap()

        let syncRow = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@", "Sync, ")
        ).firstMatch
        XCTAssertTrue(
            syncRow.waitForExistence(timeout: 90),
            "notification sync should report a status"
        )
        let acceptedRow = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@", "Accepted, ")
        ).firstMatch
        XCTAssertTrue(acceptedRow.exists, "notification sync should report accepted feeds")
        // Health rows render below the counters; pull them into view for the
        // evidence screenshot.
        app.swipeUp()
        sleep(1)
        attachAppScreenshot(of: app, named: "C04-notification-health")
    }

    // MARK: - Phase-7 identity exercise: device B steps (observation)

    /// D01: the grafted subscription and its legacy-ID played history arrive.
    @MainActor
    func testStepD01VerifyGraftArrived() throws {
        try skipUnlessSyncE2E()
        feed = .graft
        stashSystemPiPIfPresent()
        let app = launchApp()

        waitForExercisePodcast(present: true, in: app)
        XCTAssertTrue(
            waitForHistoryEpisodePlayed(true, in: app),
            "legacy-ID played history should sync to device B"
        )
        attachAppScreenshot(of: app, named: "D01-graft-arrived")
    }

    /// D02: after A's merge, the migrated progress record (new episode ID)
    /// and the legacy-ID tombstones arrive. The played state only becomes
    /// visible once this device refreshes the flipped feed and its own cache
    /// re-keys, so refresh explicitly inside the convergence loop.
    @MainActor
    func testStepD02VerifyMigratedProgressArrived() throws {
        try skipUnlessSyncE2E()
        feed = .graft
        let app = launchApp()

        XCTAssertTrue(
            waitForMigratedHistory(in: app),
            "migrated played history should converge on device B under the new IDs"
        )
        assertSingleEpisodeSearchRow(for: feed.historyEpisode, in: app)
        attachAppScreenshot(of: app, named: "D02-migrated-progress-arrived")
    }

    /// D03: stability through refresh cycles — the legacy-ID rows must stay
    /// dead under their tombstones and the migrated state must keep showing
    /// after further relaunches and refreshes.
    @MainActor
    func testStepD03VerifyStabilityThroughRefreshCycles() throws {
        try skipUnlessSyncE2E()
        feed = .graft
        let app = launchApp()

        pullToRefreshAllFeeds(in: app)
        XCTAssertTrue(
            waitForHistoryEpisodePlayed(true, in: app),
            "migrated history should stay played through refresh cycles on B"
        )
        assertSingleEpisodeSearchRow(for: feed.historyEpisode, in: app)
        attachAppScreenshot(of: app, named: "D03-stable-through-refresh")
    }

    /// D04: the cleanup (unsubscribe with cleared history) converges.
    @MainActor
    func testStepD04VerifyGraftCleanupArrived() throws {
        try skipUnlessSyncE2E()
        feed = .graft
        let app = launchApp()

        waitForExercisePodcast(present: false, in: app)
        attachAppScreenshot(of: app, named: "D04-graft-cleanup-arrived")
    }

    // MARK: - Launch-path probe

    /// Z00: diagnostic, not part of any exercise sequence. On an iOS beta
    /// device ahead of the Mac's Xcode, `XCUIApplication.launch()` can fail
    /// deterministically in the CoreDevice launch-with-progress worker while
    /// `activate()` still works. This probe checks activation both warm
    /// (instance pre-launched via devicectl) and cold (after terminate).
    @MainActor
    func testStepZ00LaunchPathProbe() throws {
        try skipUnlessSyncE2E()
        let app = XCUIApplication()
        app.activate()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 30),
            "activate should foreground a devicectl-prelaunched instance"
        )
        app.terminate()
        XCTAssertTrue(
            app.wait(for: .notRunning, timeout: 15),
            "terminate should stop the app"
        )
        app.activate()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 30),
            "activate should cold-launch after terminate"
        )
    }

    // MARK: - Gate plumbing

    private func skipUnlessSyncE2E() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("The sync-behaviors exercise requires a physical device.")
        #else
        guard ProcessInfo.processInfo.environment[Self.optInEnvironmentKey] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_OPENCAST_SYNC_E2E=1 to run the sync-behaviors exercise.")
        }
        #endif
    }

    /// A device running an iOS beta ahead of the Mac's Xcode can execute the
    /// runner while the CoreDevice launch/activate worker deterministically
    /// fails ("could not determine the process identifier"). Attach-only mode
    /// sidesteps it: the orchestrator pre-launches the app with devicectl
    /// (which still works) and the test attaches to the foreground instance
    /// without ever launching — the same capability springboard interaction
    /// relies on. Steps on such a device must not relaunch mid-step.
    private var isAttachOnly: Bool {
        ProcessInfo.processInfo.environment["OPENCAST_ATTACH_ONLY"] == "1"
    }

    @MainActor
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        if isAttachOnly {
            if app.state != .runningForeground {
                XCUIApplication(bundleIdentifier: "com.apple.springboard")
                    .icons["OpenCast"].firstMatch.tap()
            }
            XCTAssertTrue(
                app.wait(for: .runningForeground, timeout: 60),
                "attach-only mode needs the app pre-launched via devicectl"
            )
        } else {
            app.launch()
        }
        // Let the initial load and first maintenance pass settle: navigation
        // pushed while activePodcastIDs is still populating gets pruned.
        sleep(6)
        return app
    }

    /// Relaunch between convergence polls — skipped in attach-only mode,
    /// where a terminated app cannot be brought back from inside the test.
    @MainActor
    private func relaunchForConvergence(_ app: XCUIApplication) {
        guard !isAttachOnly else {
            return
        }
        app.terminate()
        app.launch()
    }

    // MARK: - Tab navigation

    /// `openSection`'s single-match tap can fail here: with the mini player
    /// accessory up, more than one tab bar (and "Library" button) exists.
    /// The paste-permission alert is springboard-hosted: it blocks every
    /// in-app tap while interruption monitors never fire on hittability
    /// checks. Dismiss it explicitly.
    @MainActor
    private func dismissPasteAlertIfPresent(waiting timeout: TimeInterval = 0) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deny = springboard.buttons["Don't Allow Paste"].firstMatch
        if timeout > 0 ? deny.waitForExistence(timeout: timeout) : deny.exists {
            if deny.isHittable {
                deny.tap()
                usleep(500_000)
            }
        }
        // The Low Battery alert blocks in-app hittability the same way the
        // paste alert does, and interruption monitors never fire on
        // hittability checks.
        let lowBattery = springboard.alerts["Low Battery"].firstMatch
        if lowBattery.exists {
            let dismiss = lowBattery.buttons["OK"].firstMatch
            if dismiss.exists, dismiss.isHittable {
                dismiss.tap()
                usleep(500_000)
            }
        }
    }

    @MainActor
    private func openTab(_ title: String, in app: XCUIApplication) {
        var attemptNotes: [String] = []
        for attempt in 0..<4 {
            dismissPasteAlertIfPresent()
            if hasArrived(at: title, in: app) {
                return
            }
            // An active search collapses the other tab buttons into the
            // tab-bar field. Tapping the collapsed tab pill restores the
            // tab set; a committed query needs its "Close"/"Cancel" first.
            if title != "Search" {
                let collapsedPill = app.tabBars.buttons.matching(
                    NSPredicate(format: "value == %@", "Collapsed")
                ).firstMatch
                if collapsedPill.exists, collapsedPill.isHittable {
                    collapsedPill.tap()
                    usleep(500_000)
                } else if app.searchFields.firstMatch.exists {
                    var dismissed = false
                    for name in ["Close", "Cancel"] {
                        let button = app.buttons[name].firstMatch
                        if button.exists, button.isHittable {
                            button.tap()
                            usleep(500_000)
                            dismissed = true
                            break
                        }
                    }
                    if !dismissed, app.keyboards.firstMatch.exists {
                        app.typeText("\n")
                    }
                }
            }
            // All tab bars: the iOS 26 search-role tab renders in its own
            // trailing tab-bar element beside the main group. A tap on a
            // scroll-minimized bar only un-minimizes it, so arrival must be
            // verified — a pushed detail similarly needs a second tap to pop.
            let tabButton = app.tabBars.buttons[title].firstMatch
            if tabButton.waitForExistence(timeout: 5), tabButton.isHittable {
                tabButton.tap()
            } else {
                let fallback = app.buttons[title].firstMatch
                if fallback.exists, fallback.isHittable {
                    fallback.tap()
                } else {
                    app.swipeDown()
                }
            }
            for _ in 0..<8 {
                if hasArrived(at: title, in: app) {
                    return
                }
                usleep(500_000)
            }
            attemptNotes.append("attempt \(attempt): tapped but '\(title)' arrival not detected")
        }
        attachDiagnostics(named: "openTab-\(title)-failure", notes: attemptNotes, app: app)
        XCTFail("\(title) tab should be reachable")
    }

    /// Arrival is tab-dependent: the iPhone's active search tab has no
    /// "Search" navigation bar — the tab button morphs into the tab-bar
    /// search field (or disappears entirely on the recents screen), while
    /// the iPad keeps a selected top-bar Search button.
    @MainActor
    private func hasArrived(at title: String, in app: XCUIApplication) -> Bool {
        if app.navigationBars[title].exists {
            return true
        }
        if title == "Search" {
            if app.searchFields.firstMatch.exists {
                return true
            }
            let tabButton = app.tabBars.buttons[title].firstMatch
            if app.tabBars.firstMatch.exists, !tabButton.exists {
                return true
            }
            if tabButton.exists, tabButton.isSelected {
                return true
            }
        }
        return false
    }

    @MainActor
    private func attachDiagnostics(named name: String, notes: [String], app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let noteAttachment = XCTAttachment(string: notes.joined(separator: "\n"))
        noteAttachment.name = "\(name)-notes"
        noteAttachment.lifetime = .keepAlways
        add(noteAttachment)
        let springboardDump = XCTAttachment(string: springboard.debugDescription)
        springboardDump.name = "\(name)-springboard"
        springboardDump.lifetime = .keepAlways
        add(springboardDump)
        let appDump = XCTAttachment(string: app.debugDescription)
        appDump.name = "\(name)-app"
        appDump.lifetime = .keepAlways
        add(appDump)
    }

    // MARK: - Library membership

    @MainActor
    private func exercisePodcastRow(in app: XCUIApplication) -> XCUIElement {
        app.buttons[feed.rowIdentifier].firstMatch
    }

    /// Scrolls the (lazy, alphabetical) library list until the seed row is
    /// realized or the bottom stops moving. Off-screen rows do not exist in
    /// the hierarchy, so presence and absence both need the scroll.
    @MainActor
    private func libraryHasExercisePodcast(in app: XCUIApplication) -> Bool {
        openTab("Library", in: app)
        let row = exercisePodcastRow(in: app)
        if row.waitForExistence(timeout: 8) {
            return true
        }

        var lastBottomIdentifier = ""
        var stalledChecks = 0
        for _ in 0..<30 {
            app.swipeUp()
            if row.exists {
                return true
            }
            let visibleRows = app.buttons.matching(
                NSPredicate(format: "identifier BEGINSWITH 'subscription-row-'")
            ).allElementsBoundByIndex
            let bottomIdentifier = visibleRows.last?.identifier ?? ""
            if !bottomIdentifier.isEmpty, bottomIdentifier == lastBottomIdentifier {
                // Two consecutive stalls mean the real end of the list; a
                // single one can be a swipe eaten by settling or a stray
                // touch on the device.
                stalledChecks += 1
                if stalledChecks >= 2 {
                    return row.exists
                }
            } else {
                stalledChecks = 0
            }
            lastBottomIdentifier = bottomIdentifier
        }
        return row.exists
    }

    @MainActor
    private func subscribeToExerciseFeed(in app: XCUIApplication) {
        if libraryHasExercisePodcast(in: app) {
            return
        }
        // Re-open the tab to settle/scroll back to top after the deep
        // presence scroll, then retry the Add tap — a tap during list
        // deceleration reads as a scroll-stop touch.
        openTab("Library", in: app)
        sleep(1)
        var sheetShown = false
        for _ in 0..<3 {
            tapAddButton(in: app)
            if app.staticTexts["Add Podcast"].waitForExistence(timeout: 8) {
                sheetShown = true
                break
            }
        }
        XCTAssertTrue(sheetShown, "Add Podcast sheet should present")
        dismissPasteAlertIfPresent(waiting: 3)
        if !app.textFields["RSS Feed URL"].waitForExistence(timeout: 3) {
            let rssMode = app.segmentedControls["Add Podcast Mode"].buttons["RSS"]
            if rssMode.waitForExistence(timeout: 3) {
                rssMode.tap()
            } else {
                app.buttons["RSS"].firstMatch.tap()
            }
        }
        let field = app.textFields["RSS Feed URL"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "RSS Feed URL field should exist")
        field.tap()
        field.typeText(feed.urlString)
        let subscribeButton = app.buttons["Subscribe"].firstMatch
        XCTAssertTrue(subscribeButton.waitForExistence(timeout: 5), "Subscribe button should exist")
        subscribeButton.tap()

        var subscribed = false
        for _ in 0..<4 {
            if libraryHasExercisePodcast(in: app) {
                subscribed = true
                break
            }
            sleep(5)
        }
        XCTAssertTrue(subscribed, "seed podcast should appear in the library after subscribing")
        // Let the post-subscribe reload/hydration settle before follow-on
        // interactions.
        sleep(8)
    }

    @MainActor
    private func tapAddButton(in app: XCUIApplication) {
        // Coordinate tap: the glass toolbar button's AX frame can miss the
        // real hit target on device, making element taps silent no-ops.
        let candidates = [
            app.navigationBars["Library"].buttons["Add"].firstMatch,
            app.navigationBars["opencast"].buttons["Add"].firstMatch,
            app.buttons["Add"].firstMatch
        ]
        for candidate in candidates {
            if candidate.waitForExistence(timeout: 3), candidate.isHittable {
                candidate.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                return
            }
        }
        XCTFail("an Add button should exist")
    }

    /// Removes the seed podcast through the library row's swipe action —
    /// the `SubscriptionRemovalModifier` surface with the same two-button
    /// confirmation shape as the podcast actions menu.
    @MainActor
    private func unsubscribeExercisePodcast(clearingHistory: Bool, in app: XCUIApplication) {
        let confirmTitle = clearingHistory ? "Remove & Clear History" : "Remove Podcast"
        for _ in 0..<3 {
            guard libraryHasExercisePodcast(in: app) else {
                continue
            }
            let row = exercisePodcastRow(in: app)
            guard row.exists, nudgeIntoView(row, in: app) else {
                continue
            }
            row.swipeLeft()
            let removeAction = app.buttons["Remove"].firstMatch
            guard removeAction.waitForExistence(timeout: 6) else {
                continue
            }
            removeAction.tap()
            let confirm = app.buttons[confirmTitle].firstMatch
            if confirm.waitForExistence(timeout: 8) {
                confirm.tap()
                sleep(2)
                return
            }
        }
        XCTFail("could not complete \(confirmTitle) via the library row swipe action")
    }

    @MainActor
    private func removeExercisePodcastIfPresent(in app: XCUIApplication) {
        guard libraryHasExercisePodcast(in: app) else {
            return
        }

        unsubscribeExercisePodcast(clearingHistory: true, in: app)
        assertExercisePodcastAbsent(in: app)
    }

    /// Old probe residue: raw feed-URL variants of the seed host (http
    /// scheme, bare host) subscribed long ago are distinct subscriptions
    /// whose shadow records used to dodge every feed-scoped delete. Remove
    /// them with cleared history so their tombstones retire them for good.
    @MainActor
    private func removeLegacySeedVariantRowsIfPresent(in app: XCUIApplication) {
        for _ in 0..<5 {
            guard let row = firstSeedVariantRow(in: app) else {
                return
            }
            guard nudgeIntoView(row, in: app) else {
                continue
            }
            row.swipeLeft()
            let removeAction = app.buttons["Remove"].firstMatch
            guard removeAction.waitForExistence(timeout: 6) else {
                continue
            }
            removeAction.tap()
            let confirm = app.buttons["Remove & Clear History"].firstMatch
            if confirm.waitForExistence(timeout: 8) {
                confirm.tap()
                sleep(2)
            }
        }
    }

    @MainActor
    private func firstSeedVariantRow(in app: XCUIApplication) -> XCUIElement? {
        openTab("Library", in: app)
        let variantQuery = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH 'subscription-row-' AND identifier CONTAINS %@ AND identifier != %@",
                "feeds.example.com",
                ExerciseFeed.seed.rowIdentifier
            )
        )
        if variantQuery.firstMatch.waitForExistence(timeout: 5) {
            return variantQuery.firstMatch
        }
        var lastBottomIdentifier = ""
        for _ in 0..<30 {
            app.swipeUp()
            if variantQuery.firstMatch.exists {
                return variantQuery.firstMatch
            }
            let visibleRows = app.buttons.matching(
                NSPredicate(format: "identifier BEGINSWITH 'subscription-row-'")
            ).allElementsBoundByIndex
            let bottomIdentifier = visibleRows.last?.identifier ?? ""
            if !bottomIdentifier.isEmpty, bottomIdentifier == lastBottomIdentifier {
                break
            }
            lastBottomIdentifier = bottomIdentifier
        }
        return variantQuery.firstMatch.exists ? variantQuery.firstMatch : nil
    }

    /// Lazy lists materialize rows a band beyond the viewport, so a row can
    /// exist (ending the presence scroll) while staying unhittable for
    /// swipes. Controlled short drags walk it into view without the
    /// overshoot of a full swipe.
    @MainActor
    private func nudgeIntoView(_ row: XCUIElement, in app: XCUIApplication) -> Bool {
        for _ in 0..<4 {
            if row.isHittable {
                return true
            }
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
            start.press(forDuration: 0.05, thenDragTo: end)
            sleep(1)
        }
        return row.isHittable
    }

    @MainActor
    private func assertExercisePodcastAbsent(in app: XCUIApplication) {
        var present = libraryHasExercisePodcast(in: app)
        var checks = 0
        while present && checks < 5 {
            sleep(5)
            present = libraryHasExercisePodcast(in: app)
            checks += 1
        }
        XCTAssertFalse(present, "seed podcast should be gone from the library")
    }

    // MARK: - Search-based episode targeting

    private func episodeRowPredicate(containing episodeTitle: String) -> NSPredicate {
        NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "episode-row-",
            episodeTitle
        )
    }

    @MainActor
    private func searchEpisodeRow(for episodeTitle: String, in app: XCUIApplication) -> XCUIElement {
        openTab("Search", in: app)

        var didType = false
        var attemptNotes: [String] = []
        for attempt in 0..<4 {
            let searchField = app.searchFields.firstMatch
            let plainField = app.textFields["Podcasts and Episodes"].firstMatch
            let field = searchField.exists ? searchField : plainField
            let navIdentifier = app.navigationBars.count > 0
                ? app.navigationBars.firstMatch.identifier
                : "none"
            attemptNotes.append(
                "attempt \(attempt): searchField=\(searchField.exists) plain=\(plainField.exists) "
                    + "hittable=\(field.exists ? String(field.isHittable) : "-") nav=\(navIdentifier)"
            )
            if field.exists {
                // The tab-bar-morphed search field often fails hit-testing
                // (its container wins) even though it is visibly tappable —
                // fall back to a coordinate tap near the magnifier.
                if field.isHittable {
                    field.tap()
                } else {
                    field.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).tap()
                }
                guard app.keyboards.firstMatch.waitForExistence(timeout: 4) else {
                    // Focus did not land (an overlay ate the tap) — clear
                    // whatever came up and retry.
                    app.swipeDown()
                    openTab("Search", in: app)
                    continue
                }
                guard field.exists else { continue }
                clearSearchField(field, in: app)
                guard field.exists else { continue }
                field.typeText(episodeTitle)
                if app.keyboards.firstMatch.exists {
                    app.typeText("\n")
                }
                didType = true
                break
            }

            // iPadOS renders `.searchable` as a nav-bar Search button that
            // expands into the field only when tapped.
            let navSearchButton = app.navigationBars.buttons["Search"].firstMatch
            if navSearchButton.exists, navSearchButton.isHittable {
                navSearchButton.tap()
                _ = app.searchFields.firstMatch.waitForExistence(timeout: 4)
                continue
            }

            openTab("Search", in: app)
            _ = app.searchFields.firstMatch.waitForExistence(timeout: 4)
        }
        if !didType {
            attachDiagnostics(named: "search-field-failure", notes: attemptNotes, app: app)
        }
        XCTAssertTrue(didType, "search field should accept the query")

        let row = app.buttons.matching(episodeRowPredicate(containing: episodeTitle)).firstMatch
        if !row.waitForExistence(timeout: 20) {
            let visibleRows = app.descendants(matching: .any).matching(
                NSPredicate(format: "identifier BEGINSWITH 'episode-row-'")
            ).allElementsBoundByIndex.prefix(6).map(\.identifier)
            attachDiagnostics(
                named: "search-row-miss",
                notes: ["query: \(episodeTitle)", "visible episode rows: \(visibleRows)"],
                app: app
            )
        }
        return row
    }

    /// A failed merge or an escaped tombstone shows up as a twin row —
    /// the retained legacy-ID episode next to its re-keyed successor.
    @MainActor
    private func assertSingleEpisodeSearchRow(for episodeTitle: String, in app: XCUIApplication) {
        let row = searchEpisodeRow(for: episodeTitle, in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 20), "the '\(episodeTitle)' row should exist")
        sleep(2)
        let matches = app.buttons.matching(episodeRowPredicate(containing: episodeTitle)).count
        XCTAssertEqual(
            matches,
            1,
            "exactly one '\(episodeTitle)' row should exist — a twin means a legacy-ID row survived"
        )
    }

    @MainActor
    private func clearSearchField(_ searchField: XCUIElement, in app: XCUIApplication) {
        let clearButton = searchField.buttons["Clear text"].firstMatch
        if clearButton.exists, clearButton.isHittable {
            clearButton.tap()
            return
        }
        if let value = searchField.value as? String, !value.isEmpty {
            searchField.typeText(
                String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count + 2)
            )
        }
    }

    // MARK: - Played-state probes

    /// Reads the history episode's played state through its search-result
    /// row context menu: "Mark Unplayed" means the record says played.
    /// Returns nil when the row or menu is not readable yet (e.g. the feed
    /// has not hydrated on this device).
    @MainActor
    private func readHistoryEpisodePlayedState(in app: XCUIApplication) -> Bool? {
        for _ in 0..<2 {
            let row = searchEpisodeRow(for: feed.historyEpisode, in: app)
            guard row.exists, row.isHittable else {
                continue
            }
            row.press(forDuration: 1.2)

            let markUnplayed = app.buttons["Mark Unplayed"].firstMatch
            let markPlayed = app.buttons["Mark Played"].firstMatch
            for _ in 0..<40 {
                if markUnplayed.exists {
                    dismissContextMenu(in: app)
                    return true
                }
                if markPlayed.exists {
                    dismissContextMenu(in: app)
                    return false
                }
                usleep(250_000)
            }
            dismissContextMenu(in: app)
        }
        return nil
    }

    @MainActor
    private func historyEpisodeIsPlayed(in app: XCUIApplication) -> Bool {
        guard let isPlayed = readHistoryEpisodePlayedState(in: app) else {
            XCTFail("context menu should expose a played-state action")
            return false
        }
        return isPlayed
    }

    @MainActor
    private func setHistoryEpisodePlayed(_ played: Bool, in app: XCUIApplication) {
        let actionTitle = played ? "Mark Played" : "Mark Unplayed"
        let oppositeTitle = played ? "Mark Unplayed" : "Mark Played"
        for _ in 0..<3 {
            let row = searchEpisodeRow(for: feed.historyEpisode, in: app)
            guard row.exists, row.isHittable else {
                continue
            }
            row.press(forDuration: 1.2)

            let action = app.buttons[actionTitle].firstMatch
            if action.waitForExistence(timeout: 5) {
                action.tap()
                return
            }
            if app.buttons[oppositeTitle].firstMatch.exists {
                // Already in the requested state.
                dismissContextMenu(in: app)
                return
            }
            dismissContextMenu(in: app)
        }
        XCTFail("could not set the history episode played state to \(played)")
    }

    @MainActor
    private func dismissContextMenu(in app: XCUIApplication) {
        // Left-middle: dismisses an open menu without hitting the tab bar
        // (bottom) or a possible system PiP window (top).
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.5)).tap()
        usleep(500_000)
    }

    // MARK: - Playback during the exercise (refetch-loop regression guard)

    @MainActor
    private func playAndPausePlaybackEpisode(in app: XCUIApplication) {
        var didPlay = false
        for _ in 0..<3 {
            let row = searchEpisodeRow(for: feed.playbackEpisode, in: app)
            guard row.exists, row.isHittable else {
                continue
            }
            // Tapping an episode row starts playback and expands the Now
            // Playing card — there is no pushed detail on this path.
            row.tap()
            let overlay = app.descendants(matching: .any)["Now Playing"]
            guard overlay.waitForExistence(timeout: 15) else {
                continue
            }
            sleep(2)
            let pause = app.buttons["Pause"].firstMatch
            if pause.exists, pause.isHittable {
                pause.tap()
            }
            // Drag the card down to return to the tab UI.
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.24))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.74))
            start.press(forDuration: 0.05, thenDragTo: end)
            _ = app.buttons["Open Now Playing"].waitForExistence(timeout: 8)
            didPlay = true
            break
        }
        XCTAssertTrue(didPlay, "tapping the playback episode row should start playback")
    }

    // MARK: - Settings: manual clear

    @MainActor
    private func clearHistoryForUnfollowedShows(in app: XCUIApplication) {
        openTab("Settings", in: app)
        let clearButton = app.buttons["Clear History for Unfollowed Shows"].firstMatch
        var swipes = 0
        while !clearButton.exists && swipes < 12 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(clearButton.waitForExistence(timeout: 10), "manual clear action should exist")
        clearButton.tap()

        let confirm = app.buttons["Clear History"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "Clear History confirmation should exist")
        confirm.tap()
        sleep(2)
    }

    // MARK: - Settings: diagnostics

    /// The persistent mini-player accessory floats over the bottom of every
    /// list once an episode is loaded, and a tap meant for a control that
    /// materialized behind it expands the Now Playing card over the whole
    /// screen instead. Dismiss the card whenever it is up.
    @MainActor
    private func dismissNowPlayingCardIfPresent(in app: XCUIApplication) {
        let overlay = app.descendants(matching: .any)["Now Playing"].firstMatch
        guard overlay.exists else {
            return
        }
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.24))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.74))
        start.press(forDuration: 0.05, thenDragTo: end)
        _ = app.buttons["Open Now Playing"].waitForExistence(timeout: 8)
    }

    /// Short drags until the element's frame sits in the middle band of the
    /// screen, clear of both the navigation chrome and the floating
    /// mini-player accessory that swallows bottom-edge taps.
    @MainActor
    private func walkClearOfBottomAccessories(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<6 {
            let frame = element.frame
            let height = app.frame.height
            if frame.minY > height * 0.15, frame.maxY < height * 0.7 {
                return
            }
            let towardTop = frame.maxY >= height * 0.7
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
            let end = app.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: towardTop ? 0.35 : 0.75)
            )
            start.press(forDuration: 0.05, thenDragTo: end)
            sleep(1)
        }
    }

    @MainActor
    private func openDiagnostics(in app: XCUIApplication) {
        dismissNowPlayingCardIfPresent(in: app)
        openTab("Settings", in: app)
        let diagnosticsLink = app.buttons["Diagnostics"].firstMatch
        var swipes = 0
        while !diagnosticsLink.exists && swipes < 12 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(diagnosticsLink.waitForExistence(timeout: 10), "Diagnostics link should exist")
        diagnosticsLink.tap()
        XCTAssertTrue(
            app.navigationBars["Diagnostics"].waitForExistence(timeout: 10),
            "Diagnostics screen should push"
        )
    }

    /// Taps "Merge Duplicate Episodes" and waits for the sweep to finish.
    /// The sweep sequentially refetches every subscribed feed, so completion
    /// is minutes, not seconds — and the app must NOT be relaunched while it
    /// runs. The tap is verified to have engaged the sweep because a tap on
    /// a button materialized behind the mini-player accessory silently
    /// expands the Now Playing card instead.
    @MainActor
    private func runMergeDuplicateEpisodes(in app: XCUIApplication) {
        let mergeButton = app.buttons["Merge Duplicate Episodes"].firstMatch
        let merging = app.staticTexts["Merging"].firstMatch
        let merged = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Last Merge, Merged")
        ).firstMatch
        let noDuplicates = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Last Merge, No Duplicates")
        ).firstMatch

        var engaged = false
        for _ in 0..<3 {
            dismissNowPlayingCardIfPresent(in: app)
            var swipes = 0
            while !mergeButton.exists && swipes < 12 {
                app.swipeUp()
                swipes += 1
            }
            XCTAssertTrue(mergeButton.waitForExistence(timeout: 10), "merge action should exist")
            walkClearOfBottomAccessories(mergeButton, in: app)
            guard mergeButton.exists, mergeButton.isHittable else {
                continue
            }
            mergeButton.tap()

            // The sweep is engaged once the progress row or a result row is
            // up; a stray Now Playing expansion means the accessory ate the
            // tap — dismiss and retry.
            for _ in 0..<16 {
                if merging.exists || merged.exists || noDuplicates.exists {
                    engaged = true
                    break
                }
                if app.descendants(matching: .any)["Now Playing"].firstMatch.exists {
                    break
                }
                usleep(500_000)
            }
            if engaged {
                break
            }
        }
        XCTAssertTrue(engaged, "the merge sweep should visibly start")

        // Full-library refetch: allow well beyond the sync timeout.
        let deadline = Date.now.addingTimeInterval(900)
        while Date.now < deadline {
            if merged.exists || noDuplicates.exists {
                break
            }
            sleep(5)
        }
        XCTAssertTrue(
            merged.exists,
            "the sweep should report Merged — the flipped GUIDs re-key every grafted episode"
        )
    }

    // MARK: - Sync waits (device B)

    /// Waits for the seed podcast's library presence to converge, relaunching
    /// periodically so each relaunch's first-active full maintenance pass
    /// pulls imports even if a push never arrives.
    @MainActor
    private func waitForExercisePodcast(present: Bool, in app: XCUIApplication) {
        let deadline = Date.now.addingTimeInterval(Self.syncTimeout)
        var attempt = 0
        while Date.now < deadline {
            if libraryHasExercisePodcast(in: app) == present {
                return
            }
            attempt += 1
            sleep(20)
            if attempt % 2 == 0 {
                relaunchForConvergence(app)
            }
        }
        XCTFail("seed podcast presence did not converge to \(present) within \(Int(Self.syncTimeout))s")
    }

    @MainActor
    private func waitForHistoryEpisodePlayed(_ expected: Bool, in app: XCUIApplication) -> Bool {
        let deadline = Date.now.addingTimeInterval(Self.syncTimeout)
        while Date.now < deadline {
            if readHistoryEpisodePlayedState(in: app) == expected {
                return true
            }
            sleep(20)
            relaunchForConvergence(app)
        }
        return false
    }

    /// Migrated progress only becomes visible after this device refetches
    /// the flipped feed and re-keys its cache rows — the hourly staleness
    /// gate means relaunches alone never refetch it in time, so refresh
    /// explicitly each pass.
    @MainActor
    private func waitForMigratedHistory(in app: XCUIApplication) -> Bool {
        let deadline = Date.now.addingTimeInterval(Self.syncTimeout)
        while Date.now < deadline {
            pullToRefreshAllFeeds(in: app)
            if readHistoryEpisodePlayedState(in: app) == true {
                return true
            }
            sleep(15)
            relaunchForConvergence(app)
            sleep(6)
        }
        return false
    }

    /// Pulls to refresh on the Inbox tab, which is a List with a
    /// `.refreshable` full-library refresh on every size class — the iPad
    /// Library is a ScrollView grid whose pull control cannot be relied on.
    @MainActor
    private func pullToRefreshAllFeeds(in app: XCUIApplication) {
        dismissNowPlayingCardIfPresent(in: app)
        openTab("Inbox", in: app)
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        start.press(forDuration: 0.1, thenDragTo: end)
        // refreshAll fans out across the whole library; give the grafted
        // feed's fetch time to land before probing.
        sleep(15)
    }

    // MARK: - Evidence
}
