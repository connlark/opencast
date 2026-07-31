import XCTest

/// Two-device CloudKit exercise driver (opt-in, physical devices).
///
/// Each `testStep…` method is one device-side step of the exercise. The
/// external orchestrator runs them one at a time, alternating devices:
///
///   A00 → A01 → B01 → A02 → B02 → A03 → B03 → A04 → B04 → A05 → B05 →
///   A06 → B06 → A07 → B07
///
/// Device A performs the mutations (subscribe, play/pause, unsubscribe
/// variants, manual clear); device B only observes convergence. The synthetic
/// fixture keeps the exercise independent from fixtures other suites depend
/// on. Library membership is driven through subscription rows and
/// swipe actions; played state is read and written through search-result
/// row context menus, which stay stable while the freshly synced feed's
/// navigation pushes can get pruned. Set `TEST_RUNNER_OPENCAST_SYNC_E2E=1`
/// to run.
final class SyncBehaviorsDeviceE2EUITests: XCTestCase {
    private static let optInEnvironmentKey = "OPENCAST_SYNC_E2E"
    private static let feedURLString = "https://feeds.example.com/sync-e2e.xml"
    private static let historyEpisode = "Seed One"
    /// Seed episode (9 s): fresh subscriptions default auto-detect off, so
    /// playing it cannot trigger a standing ad-detection pass or its dialogs.
    private static let playbackEpisode = "Root Three"
    private static let syncTimeout: TimeInterval = 420

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
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let start = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.18))
        let end = springboard.coordinate(withNormalizedOffset: CGVector(dx: 1.1, dy: 0.5))
        start.press(forDuration: 0.3, thenDragTo: end)
        sleep(2)

        // Environment prep: title-keyed episode reads later in the flow are
        // ambiguous while a legacy raw-URL variant of the seed feed carries
        // twin episodes, so retire any such subscription up front.
        let app = launchApp()
        removeLegacySeedVariantRowsIfPresent(in: app)
    }

    @MainActor
    func testStepA01SubscribeAndSeedHistory() throws {
        try skipUnlessSyncE2E()
        let app = launchApp()

        removeSeedPodcastIfPresent(in: app)
        subscribeToSeedFeed(in: app)
        playAndPausePlaybackEpisode(in: app)
        setHistoryEpisodePlayed(true, in: app)
        XCTAssertTrue(
            historyEpisodeIsPlayed(in: app),
            "history episode should read as played after marking"
        )
        attachScreen(named: "A01-subscribed-history-seeded", app: app)
    }

    @MainActor
    func testStepA02UnsubscribeKeepingHistory() throws {
        try skipUnlessSyncE2E()
        let app = launchApp()

        playAndPausePlaybackEpisode(in: app)
        unsubscribeSeedPodcast(clearingHistory: false, in: app)
        assertSeedPodcastAbsent(in: app)
        attachScreen(named: "A02-unsubscribed-default", app: app)
    }

    @MainActor
    func testStepA03ResubscribeVerifyHistoryKept() throws {
        try skipUnlessSyncE2E()
        let app = launchApp()

        subscribeToSeedFeed(in: app)
        XCTAssertTrue(
            waitForHistoryEpisodePlayed(true, in: app),
            "history should survive default unsubscribe + resubscribe on A"
        )
        attachScreen(named: "A03-resubscribed-history-kept", app: app)
    }

    @MainActor
    func testStepA04UnsubscribeClearingHistory() throws {
        try skipUnlessSyncE2E()
        let app = launchApp()

        playAndPausePlaybackEpisode(in: app)
        unsubscribeSeedPodcast(clearingHistory: true, in: app)
        assertSeedPodcastAbsent(in: app)
        attachScreen(named: "A04-unsubscribed-clear-history", app: app)
    }

    @MainActor
    func testStepA05ResubscribeVerifyHistoryCleared() throws {
        try skipUnlessSyncE2E()
        let app = launchApp()

        subscribeToSeedFeed(in: app)
        // Convergence, not an instant read: a not-yet-imported CloudKit copy
        // may flash into view until tombstone enforcement deletes it.
        XCTAssertTrue(
            waitForHistoryEpisodePlayed(false, in: app),
            "Unsubscribe & Clear History should converge to no played state on A"
        )
        attachScreen(named: "A05-resubscribed-history-cleared", app: app)
    }

    @MainActor
    func testStepA06SeedUnfollowedHistoryAndManualClear() throws {
        try skipUnlessSyncE2E()
        let app = launchApp()

        setHistoryEpisodePlayed(true, in: app)
        XCTAssertTrue(historyEpisodeIsPlayed(in: app), "played marker should stick before unsubscribe")
        unsubscribeSeedPodcast(clearingHistory: false, in: app)
        assertSeedPodcastAbsent(in: app)

        clearHistoryForUnfollowedShows(in: app)

        subscribeToSeedFeed(in: app)
        XCTAssertTrue(
            waitForHistoryEpisodePlayed(false, in: app),
            "manual clear should converge to no played state on A"
        )
        attachScreen(named: "A06-manual-clear-applied", app: app)
    }

    @MainActor
    func testStepA07Cleanup() throws {
        try skipUnlessSyncE2E()
        let app = launchApp()

        removeSeedPodcastIfPresent(in: app)
        removeLegacySeedVariantRowsIfPresent(in: app)
        assertSeedPodcastAbsent(in: app)
        attachScreen(named: "A07-cleanup", app: app)
    }

    // MARK: - Device B steps (observation)

    @MainActor
    func testStepB01VerifySubscriptionAndHistoryArrived() throws {
        try skipUnlessSyncE2E()
        let app = launchApp()

        waitForSeedPodcast(present: true, in: app)
        XCTAssertTrue(
            waitForHistoryEpisodePlayed(true, in: app),
            "played history should sync to device B"
        )
        attachScreen(named: "B01-subscription-and-history-arrived", app: app)
    }

    @MainActor
    func testStepB02VerifyUnsubscribeArrived() throws {
        try skipUnlessSyncE2E()
        let app = launchApp()

        waitForSeedPodcast(present: false, in: app)
        attachScreen(named: "B02-unsubscribe-arrived", app: app)
    }

    @MainActor
    func testStepB03VerifyHistoryVisibleAfterResubscribe() throws {
        try skipUnlessSyncE2E()
        let app = launchApp()

        waitForSeedPodcast(present: true, in: app)
        XCTAssertTrue(
            waitForHistoryEpisodePlayed(true, in: app),
            "history should be visible on device B after the default-unsubscribe cycle"
        )
        attachScreen(named: "B03-history-visible", app: app)
    }

    @MainActor
    func testStepB04VerifyClearHistoryUnsubscribeArrived() throws {
        try skipUnlessSyncE2E()
        let app = launchApp()

        waitForSeedPodcast(present: false, in: app)
        attachScreen(named: "B04-clear-unsubscribe-arrived", app: app)
    }

    @MainActor
    func testStepB05VerifyHistoryGone() throws {
        try skipUnlessSyncE2E()
        let app = launchApp()

        waitForSeedPodcast(present: true, in: app)
        XCTAssertTrue(
            waitForHistoryEpisodePlayed(false, in: app),
            "Unsubscribe & Clear History should converge to no played state on B"
        )
        attachScreen(named: "B05-history-gone", app: app)
    }

    @MainActor
    func testStepB06VerifyManualClearConverged() throws {
        try skipUnlessSyncE2E()
        let app = launchApp()

        waitForSeedPodcast(present: true, in: app)
        XCTAssertTrue(
            waitForHistoryEpisodePlayed(false, in: app),
            "manual clear on A should converge to no played state on B"
        )
        attachScreen(named: "B06-manual-clear-converged", app: app)
    }

    @MainActor
    func testStepB07VerifyCleanupArrived() throws {
        try skipUnlessSyncE2E()
        let app = launchApp()

        waitForSeedPodcast(present: false, in: app)
        attachScreen(named: "B07-cleanup-arrived", app: app)
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

    @MainActor
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        // Let the initial load and first maintenance pass settle: navigation
        // pushed while activePodcastIDs is still populating gets pruned.
        sleep(6)
        return app
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

    private static let seedRowIdentifier = "subscription-row-\(feedURLString)"

    @MainActor
    private func seedPodcastRow(in app: XCUIApplication) -> XCUIElement {
        app.buttons[Self.seedRowIdentifier].firstMatch
    }

    /// Scrolls the (lazy, alphabetical) library list until the seed row is
    /// realized or the bottom stops moving. Off-screen rows do not exist in
    /// the hierarchy, so presence and absence both need the scroll.
    @MainActor
    private func libraryHasSeedPodcast(in app: XCUIApplication) -> Bool {
        openTab("Library", in: app)
        let row = seedPodcastRow(in: app)
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
    private func subscribeToSeedFeed(in app: XCUIApplication) {
        if libraryHasSeedPodcast(in: app) {
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
        field.typeText(Self.feedURLString)
        let subscribeButton = app.buttons["Subscribe"].firstMatch
        XCTAssertTrue(subscribeButton.waitForExistence(timeout: 5), "Subscribe button should exist")
        subscribeButton.tap()

        var subscribed = false
        for _ in 0..<4 {
            if libraryHasSeedPodcast(in: app) {
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
    private func unsubscribeSeedPodcast(clearingHistory: Bool, in app: XCUIApplication) {
        let confirmTitle = clearingHistory ? "Remove & Clear History" : "Remove Podcast"
        for _ in 0..<3 {
            guard libraryHasSeedPodcast(in: app) else {
                continue
            }
            let row = seedPodcastRow(in: app)
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
    private func removeSeedPodcastIfPresent(in app: XCUIApplication) {
        guard libraryHasSeedPodcast(in: app) else {
            return
        }

        unsubscribeSeedPodcast(clearingHistory: true, in: app)
        assertSeedPodcastAbsent(in: app)
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
                Self.seedRowIdentifier
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
    private func assertSeedPodcastAbsent(in app: XCUIApplication) {
        var present = libraryHasSeedPodcast(in: app)
        var checks = 0
        while present && checks < 5 {
            sleep(5)
            present = libraryHasSeedPodcast(in: app)
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
            let row = searchEpisodeRow(for: Self.historyEpisode, in: app)
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
            let row = searchEpisodeRow(for: Self.historyEpisode, in: app)
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
            let row = searchEpisodeRow(for: Self.playbackEpisode, in: app)
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

    // MARK: - Sync waits (device B)

    /// Waits for the seed podcast's library presence to converge, relaunching
    /// periodically so each relaunch's first-active full maintenance pass
    /// pulls imports even if a push never arrives.
    @MainActor
    private func waitForSeedPodcast(present: Bool, in app: XCUIApplication) {
        let deadline = Date.now.addingTimeInterval(Self.syncTimeout)
        var attempt = 0
        while Date.now < deadline {
            if libraryHasSeedPodcast(in: app) == present {
                return
            }
            attempt += 1
            sleep(20)
            if attempt % 2 == 0 {
                app.terminate()
                app.launch()
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
            app.terminate()
            app.launch()
        }
        return false
    }

    // MARK: - Evidence

    @MainActor
    private func attachScreen(named name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
