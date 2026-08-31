import XCTest

/// Opt-in device E2E for Chapters & Summary (remote transcript analysis).
/// Runs against a physical device with its on-disk store, the network, and a
/// self-hosted development TranscriptAnalysisWorker via App Attest — no
/// `--opencast-ui-testing` seams. Run each test individually via
/// `-only-testing` with
/// `TEST_RUNNER_OPENCAST_DEVICE_E2E=1`; the class skips everywhere else so
/// simulator regression runs are unaffected.
///
/// Legs:
/// - 02: a completed transcript triggers no auto-analysis (generation is
///   manual-only, with the per-show opt-in retired); the Generate entry
///   renders below the show notes, the first tap routes through the
///   one-time disclosure dialog, the explicit run reaches cards through the
///   visible running state, and a chapter tap seeks playback.
/// - 03: a `podcast:chapters` feed suppresses generation and explains
///   (creator metadata wins) — served by the grafted exercise feed, whose
///   "Bridge Three" declares creator chapters.
final class TranscriptAnalysisDeviceE2EUITests: XCTestCase {
    private static let optInEnvironmentKey = "OPENCAST_DEVICE_E2E"

    /// Real show for legs 01/02: short daily episodes keep on-device
    /// transcription in the minutes range.
    private static let realShowFeedURL = "https://feeds.npr.org/510318/podcast.xml"
    private static var realShowRowPredicate: NSPredicate {
        NSPredicate(
            format: "identifier BEGINSWITH %@ AND identifier CONTAINS %@",
            "subscription-row-",
            "feeds.npr.org/510318"
        )
    }

    private static let graftFeedURL = "https://graft.example.com/feed.xml"
    private static var graftRowPredicate: NSPredicate {
        NSPredicate(
            format: "identifier BEGINSWITH %@ AND identifier CONTAINS %@",
            "subscription-row-",
            "graft.example.com"
        )
    }
    private static let creatorChaptersEpisode = "Bridge Three"
    private static let diagnosticEpisodeTitle =
        ProcessInfo.processInfo.environment["OPENCAST_TRANSCRIPT_ANALYSIS_DIAGNOSTIC_EPISODE_TITLE"]
            ?? "Example Episode"

    private static let generateButtonTitle = "Generate Chapters & Summary"
    private static let runningCopy = "Generating chapters and a summary…"
    private static let creatorGateCopyFragment = "publishes its own chapters"

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

    // MARK: - Gates

    /// One-time device prep: set OpenCast's "Paste from Other Apps" to
    /// Deny. The Add Podcast sheet's clipboard probe is a synchronous
    /// `UIPasteboard.general.string` read; with a universal-clipboard item
    /// around, iOS raises its paste prompt, the app's main thread parks
    /// inside the read (every app-side AX snapshot then times out), and the
    /// prompt's alert is hosted by a remote process XCUITest cannot see or
    /// tap (kAXErrorServerNotFound) — recorded during this gate's bring-up.
    /// Denying the permission makes the read return nil instantly, forever.
    @MainActor
    func testDeviceE2E00DenyPastePermissionOnce() throws {
        try skipUnlessDeviceE2E()
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()
        _ = settings.wait(for: .runningForeground, timeout: 15)

        let searchField = settings.searchFields.firstMatch
        assertExists(searchField, named: "Settings search field", timeout: 15)
        searchField.tap()
        searchField.typeText("opencast")
        sleep(2)
        attachTimestampedSmokeScreenshot(named: "00-settings-search")

        let appRow = settings.cells.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "opencast")
        ).firstMatch
        let appHit = appRow.exists
            ? appRow
            : settings.staticTexts.matching(
                NSPredicate(format: "label CONTAINS[c] %@", "opencast")
            ).firstMatch
        assertExists(appHit, named: "opencast search result", timeout: 10)
        appHit.tap()

        let pasteRow = settings.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "Paste from Other Apps")
        ).firstMatch
        assertExists(pasteRow, named: "Paste from Other Apps row", timeout: 15)
        if !pasteRow.isHittable {
            settings.swipeUp()
        }
        pasteRow.tap()

        let deny = settings.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Deny")
        ).firstMatch
        assertExists(deny, named: "Deny option", timeout: 10)
        deny.tap()
        sleep(1)
        attachTimestampedSmokeScreenshot(named: "00-paste-denied")
        settings.terminate()
    }

    /// Manual-only proof: a completed transcript triggers NO analysis on its
    /// own; the Generate entry waits below the show notes, the first tap
    /// routes through the one-time disclosure dialog, and the explicit run
    /// reaches cards through the visible running state — then a chapter tap
    /// seeks playback to the chapter start.
    @MainActor
    func testDeviceE2E02ManualGenerateDisclosureRenderAndSeek() throws {
        try skipUnlessDeviceE2E()
        let app = launchRealApp()

        openShowPage(matching: Self.realShowRowPredicate, subscribingTo: Self.realShowFeedURL, in: app)

        let episodeTitle = openEpisodeDetail(at: 0, in: app)
        resetTranscriptIfPresent(in: app)
        downloadAndStartTranscript(in: app)
        attachTimestampedSmokeScreenshot(named: "02-transcribing")
        XCTAssertTrue(
            waitForTranscriptCompleted(in: app, timeout: 1200),
            "on-device transcription should complete"
        )
        attachTimestampedSmokeScreenshot(named: "02-transcript-completed")

        // Auto-run is retired: completion must leave the episode un-analyzed
        // with the Generate entry offered. The full sweep materializes the
        // whole detail before the absence checks.
        Thread.sleep(forTimeInterval: 45)
        sweepDetail(in: app) { false }
        XCTAssertFalse(
            staticText(exactly: "Chapters", in: app).exists,
            "transcript completion must not produce a chapters card without a tap"
        )
        XCTAssertFalse(
            staticText(containing: Self.runningCopy, in: app).exists,
            "transcript completion must not start an analysis on its own"
        )
        attachTimestampedSmokeScreenshot(named: "02-no-auto-run")

        let generate = app.buttons[Self.generateButtonTitle]
        sweepDetail(in: app) { generate.exists }
        assertExists(generate, named: "Generate button below the show notes", timeout: 20)
        attachTimestampedSmokeScreenshot(named: "02-generate-offered")
        // Coordinate tap: the glass button eats element.tap() (recorded
        // finding; the first run's tap synthesized and nothing started).
        generate.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        // First-ever tap on this install routes through the one-time
        // disclosure dialog; a rerun against the existing store has already
        // acknowledged it, so the dialog is asserted only when it appears.
        let disclosureTitle = staticText(containing: "Generate Chapters & Summary?", in: app)
        if disclosureTitle.waitForExistence(timeout: 8) {
            assertExists(
                staticText(containing: "Your audio is never sent.", in: app),
                named: "disclosure dialog body",
                timeout: 5
            )
            XCTAssertFalse(
                staticText(containing: "shared with other listeners", in: app).exists,
                "sharing sentence must be absent while the sharing flag is dark"
            )
            assertExists(
                staticText(containing: "Uses transcription minutes.", in: app),
                named: "disclosure minutes sentence",
                timeout: 5
            )
            attachTimestampedSmokeScreenshot(named: "02-disclosure-dialog")
            let confirm = app.buttons["Generate"].firstMatch
            assertExists(confirm, named: "disclosure Generate confirmation", timeout: 5)
            confirm.tap()
        }

        assertExists(
            staticText(containing: Self.runningCopy, in: app),
            named: "running state after explicit Generate",
            timeout: 60
        )
        attachTimestampedSmokeScreenshot(named: "02-generating")
        XCTAssertTrue(
            waitForGeneratedCards(in: app, timeout: 600),
            "explicit Generate should produce chapters + summary cards"
        )
        assertExists(staticText(exactly: "Generated", in: app), named: "Generated content tag", timeout: 5)
        attachTimestampedSmokeScreenshot(named: "02-cards-rendered")

        let (chapter, expectedStart) = try lastChapter(in: app)
        chapter.tap()
        let elapsed = try readNowPlayingElapsed(in: app)
        attachTimestampedSmokeScreenshot(named: "02-after-chapter-seek")
        XCTAssertGreaterThanOrEqual(
            elapsed, expectedStart - 5,
            "playback should start at the tapped chapter (expected ≥ \(expectedStart - 5)s, got \(elapsed)s) for \(episodeTitle)"
        )
        XCTAssertLessThanOrEqual(
            elapsed, expectedStart + 150,
            "playback should not run far past the tapped chapter start (expected ≤ \(expectedStart + 150)s, got \(elapsed)s)"
        )
        pausePlaybackIfPossible(in: app)
    }

    /// Creator metadata wins: on the grafted feed's `podcast:chapters`
    /// episode, a completed transcript yields the explanation card — never
    /// a Generate action, never generated cards.
    @MainActor
    func testDeviceE2E03CreatorChaptersGateSuppressesGeneration() throws {
        try skipUnlessDeviceE2E()
        let app = launchRealApp()

        // Fresh subscribe so the feed parse carries the chapters declaration
        // (the fixture gained it for this gate).
        removeSubscriptionIfPresent(matching: Self.graftRowPredicate, in: app)
        openShowPage(matching: Self.graftRowPredicate, subscribingTo: Self.graftFeedURL, in: app)

        openEpisodeDetail(containing: Self.creatorChaptersEpisode, in: app)
        resetTranscriptIfPresent(in: app)
        downloadAndStartTranscript(in: app)
        XCTAssertTrue(
            waitForTranscriptCompleted(in: app, timeout: 600),
            "the 9-second fixture episode should transcribe quickly"
        )

        let gateCopy = staticText(containing: Self.creatorGateCopyFragment, in: app)
        sweepDetail(in: app) { gateCopy.exists }
        assertExists(gateCopy, named: "creator-chapters explanation card", timeout: 60)
        attachTimestampedSmokeScreenshot(named: "03-creator-gate-explains")

        Thread.sleep(forTimeInterval: 45)
        sweepDetail(in: app) { false }
        XCTAssertFalse(
            app.buttons[Self.generateButtonTitle].exists,
            "creator-chapters episode must not offer Generate"
        )
        XCTAssertFalse(
            staticText(exactly: "Chapters", in: app).exists,
            "creator-chapters episode must not get a generated chapters card"
        )
        XCTAssertFalse(
            staticText(containing: Self.runningCopy, in: app).exists,
            "creator-chapters episode must not auto-run an analysis"
        )
        attachTimestampedSmokeScreenshot(named: "03-generation-suppressed")
    }

    /// Diagnostics probe, not a gate: captures the Downloads screen so a
    /// failing device download's message is readable from the test log.
    @MainActor
    func testDeviceE2E99DownloadsDiagnostics() throws {
        try skipUnlessDeviceE2E()
        let app = launchRealApp()
        for _ in 0..<4 {
            dismissBlockingAlertsIfPresent()
            let tab = app.buttons["Downloads"].firstMatch
            if tab.exists, tab.isHittable {
                tab.tap()
            }
            if app.navigationBars["Downloads"].waitForExistence(timeout: 5) {
                break
            }
        }
        sleep(2)
        attachTimestampedSmokeScreenshot(named: "99-downloads-screen")

        let title = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", Self.diagnosticEpisodeTitle)
        ).firstMatch
        for _ in 0..<15 where !title.exists {
            app.swipeUp()
        }
        attachTimestampedSmokeScreenshot(named: "99-upfirst-row")
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "99-downloads-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)

        // Row-scoped retry: watch one fresh attempt land or fail.
        let cell = app.cells.containing(
            NSPredicate(format: "label CONTAINS %@", Self.diagnosticEpisodeTitle)
        ).firstMatch
        if cell.exists, cell.buttons.firstMatch.exists {
            cell.buttons.firstMatch
                .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            for step in 1...4 {
                sleep(8)
                attachTimestampedSmokeScreenshot(named: "99-after-retry-\(step)")
            }
            let after = XCTAttachment(string: app.debugDescription)
            after.name = "99-after-retry-hierarchy"
            after.lifetime = .keepAlways
            add(after)
        }
    }

    // MARK: - Gate plumbing

    private func skipUnlessDeviceE2E() throws {
        #if targetEnvironment(simulator)
            throw XCTSkip("Transcript-analysis E2E requires a physical device.")
        #else
        guard ProcessInfo.processInfo.environment[Self.optInEnvironmentKey] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_OPENCAST_DEVICE_E2E=1 to run the device E2E.")
        }
        #endif
    }

    @MainActor
    private func launchRealApp() -> XCUIApplication {
        stashSystemPiPIfPresent()
        let app = XCUIApplication()
        app.launch()
        // Let the initial load and first maintenance pass settle.
        sleep(6)
        return app
    }

    /// A system picture-in-picture window floating over the toolbar swallows
    /// taps on top-of-screen controls (recorded device finding). Stash it off
    /// the right edge — a harmless quick swipe when no PiP is up.
    @MainActor
    private func stashSystemPiPIfPresent() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let start = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.18))
        let end = springboard.coordinate(withNormalizedOffset: CGVector(dx: 1.1, dy: 0.5))
        start.press(forDuration: 0.3, thenDragTo: end)
        sleep(2)
    }

    /// The paste-permission alert is springboard-hosted: it blocks every
    /// in-app tap, interruption monitors never fire for it, and — recorded
    /// during this gate's bring-up — APP-side snapshot queries hang for
    /// minutes while it is up. Always wait for and dismiss it on the
    /// springboard side BEFORE the next app-side query.
    @MainActor
    private func dismissBlockingAlertsIfPresent(waiting timeout: TimeInterval = 0) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deny = springboard.buttons["Don't Allow Paste"].firstMatch
        if timeout > 0 ? deny.waitForExistence(timeout: timeout) : deny.exists {
            if deny.isHittable {
                deny.tap()
            } else {
                deny.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
            usleep(500_000)
        }
        let lowBattery = springboard.alerts["Low Battery"].firstMatch
        if lowBattery.exists {
            let dismiss = lowBattery.buttons["OK"].firstMatch
            if dismiss.exists, dismiss.isHittable {
                dismiss.tap()
                usleep(500_000)
            }
        }
    }

    // MARK: - Library navigation

    @MainActor
    private func openLibrary(in app: XCUIApplication) {
        for _ in 0..<4 {
            dismissBlockingAlertsIfPresent()
            if app.navigationBars["Library"].exists {
                return
            }
            let tabButton = app.tabBars.buttons["Library"].firstMatch
            if tabButton.waitForExistence(timeout: 5), tabButton.isHittable {
                tabButton.tap()
            } else {
                let fallback = app.buttons["Library"].firstMatch
                if fallback.exists, fallback.isHittable {
                    fallback.tap()
                } else {
                    app.swipeDown()
                }
            }
            for _ in 0..<8 {
                if app.navigationBars["Library"].exists {
                    return
                }
                usleep(500_000)
            }
        }
        XCTFail("Library tab should be reachable")
    }

    /// Scrolls the lazy library list until the row is realized or the bottom
    /// stops moving (off-screen rows do not exist in the hierarchy).
    @MainActor
    private func libraryRow(matching predicate: NSPredicate, in app: XCUIApplication) -> XCUIElement? {
        openLibrary(in: app)
        let row = app.buttons.matching(predicate).firstMatch
        if row.waitForExistence(timeout: 8) {
            return row
        }

        var lastBottomIdentifier = ""
        var stalledChecks = 0
        for _ in 0..<30 {
            app.swipeUp()
            if row.exists {
                return row
            }
            let visibleRows = app.buttons.matching(
                NSPredicate(format: "identifier BEGINSWITH 'subscription-row-'")
            ).allElementsBoundByIndex
            // An unchanged (or empty) bottom row twice in a row means the
            // list has stopped moving — the target is genuinely absent.
            let bottomIdentifier = visibleRows.last?.identifier ?? ""
            if bottomIdentifier == lastBottomIdentifier {
                stalledChecks += 1
                if stalledChecks >= 2 {
                    return row.exists ? row : nil
                }
            } else {
                stalledChecks = 0
            }
            lastBottomIdentifier = bottomIdentifier
        }
        return row.exists ? row : nil
    }

    @MainActor
    private func openShowPage(
        matching predicate: NSPredicate,
        subscribingTo feedURL: String,
        in app: XCUIApplication
    ) {
        var row = libraryRow(matching: predicate, in: app)
        if row == nil {
            subscribe(to: feedURL, in: app)
            row = libraryRow(matching: predicate, in: app)
        }
        guard let row else {
            XCTFail("subscription row should exist after subscribing to \(feedURL)")
            return
        }
        if !row.isHittable {
            app.swipeUp()
        }
        row.tap()
        XCTAssertTrue(
            episodeRows(in: app).firstMatch.waitForExistence(timeout: 20),
            "show page should open from the library row"
        )
    }

    @MainActor
    private func subscribe(to feedURL: String, in app: XCUIApplication) {
        openLibrary(in: app)
        sleep(1)
        var sheetShown = false
        outer: for _ in 0..<3 {
            tapAddButton(in: app)
            // Opening the sheet pre-reads the pasteboard, raising the paste
            // prompt moments later. Springboard-side wait FIRST — an
            // app-side query while the prompt is up never returns.
            dismissBlockingAlertsIfPresent(waiting: 4)
            for _ in 0..<3 {
                if app.staticTexts["Add Podcast"].waitForExistence(timeout: 3) {
                    sheetShown = true
                    break outer
                }
                dismissBlockingAlertsIfPresent(waiting: 2)
            }
        }
        XCTAssertTrue(sheetShown, "Add Podcast sheet should present")
        dismissBlockingAlertsIfPresent()
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
        dismissBlockingAlertsIfPresent(waiting: 2)
        field.typeText(feedURL)
        let subscribeButton = app.buttons["Subscribe"].firstMatch
        XCTAssertTrue(subscribeButton.waitForExistence(timeout: 5), "Subscribe button should exist")
        subscribeButton.tap()
        // Let the post-subscribe reload/hydration settle.
        sleep(8)
    }

    @MainActor
    private func tapAddButton(in app: XCUIApplication) {
        // Coordinate tap: the glass toolbar button's AX frame can miss the
        // real hit target on device, making element taps silent no-ops.
        let candidates = [
            app.navigationBars["Library"].buttons["Add"].firstMatch,
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

    @MainActor
    private func removeSubscriptionIfPresent(matching predicate: NSPredicate, in app: XCUIApplication) {
        for _ in 0..<3 {
            guard let row = libraryRow(matching: predicate, in: app) else {
                return
            }
            if !row.isHittable {
                app.swipeUp()
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

    // MARK: - Episode detail

    @MainActor
    private func episodeRows(in app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'episode-row-'"))
    }

    /// Opens episode detail from the show page's episode list (row tap plays;
    /// detail goes through the context menu — recorded device finding).
    /// Returns the row's label for later diagnostics.
    @MainActor
    @discardableResult
    private func openEpisodeDetail(at index: Int, in app: XCUIApplication) -> String {
        let rows = episodeRows(in: app)
        if !rows.firstMatch.waitForExistence(timeout: 10) {
            app.swipeUp()
        }
        assertExists(rows.firstMatch, named: "episode rows on the show page", timeout: 20)
        var row = rows.element(boundBy: index)
        for _ in 0..<6 where !(row.exists && row.isHittable) {
            app.swipeUp()
            row = rows.element(boundBy: index)
        }
        let label = row.label
        openDetail(from: row, in: app)
        return label
    }

    @MainActor
    private func openEpisodeDetail(containing episodeTitle: String, in app: XCUIApplication) {
        let row = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                "episode-row-",
                episodeTitle
            )
        ).firstMatch
        for _ in 0..<6 where !row.exists {
            app.swipeUp()
        }
        assertExists(row, named: "episode row for \(episodeTitle)", timeout: 20)
        openDetail(from: row, in: app)
    }

    @MainActor
    private func openDetail(from row: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<3 {
            row.press(forDuration: 1.2)
            let detailsButton = app.buttons["View Episode Details"]
            if detailsButton.waitForExistence(timeout: 4) {
                detailsButton.tap()
                break
            }
        }
        assertExists(app.buttons["Episode Actions"], named: "episode detail toolbar", timeout: 15)
    }

    // MARK: - Episode Actions menu plumbing

    @MainActor
    private func openEpisodeActionsMenu(in app: XCUIApplication) {
        let menuButton = app.buttons["Episode Actions"]
        assertExists(menuButton, named: "Episode Actions menu", timeout: 15)
        menuButton.tap()
    }

    /// Taps the dimming overlay of an open menu; while a menu is up the tap
    /// never reaches the controls underneath.
    @MainActor
    private func dismissMenu(in app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.08)).tap()
        usleep(500_000)
    }

    /// Un-burns a previously exercised episode: "Delete Transcript" removes
    /// the transcript AND any analysis, restoring the virgin detail state.
    @MainActor
    private func resetTranscriptIfPresent(in app: XCUIApplication) {
        openEpisodeActionsMenu(in: app)
        let deleteButton = app.buttons["Delete Transcript"]
        if deleteButton.waitForExistence(timeout: 4), deleteButton.isHittable {
            deleteButton.tap()
            _ = deleteButton.waitForNonExistence(timeout: 5)
        } else {
            dismissMenu(in: app)
        }
    }

    /// Download (if not yet downloaded), then start the on-device transcript
    /// as soon as the menu offers it. The download is triggered from the
    /// page-level control: the menu's Download twin shares its label, and a
    /// label-keyed button query resolves to the page one — which sits
    /// behind the open menu's scrim and is never hittable (recorded during
    /// this gate's bring-up, a silent 10-minute no-op loop).
    @MainActor
    private func downloadAndStartTranscript(in app: XCUIApplication) {
        // NPR's DAI redirect chain served ~14 MB at roughly 8 minutes during
        // bring-up; the budget covers a slow chain plus one restart.
        let deadline = Date().addingTimeInterval(1200)
        while Date() < deadline {
            openEpisodeActionsMenu(in: app)
            let generate = app.buttons["Generate Transcript"]
            if generate.waitForExistence(timeout: 3), generate.isHittable {
                generate.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                return
            }

            // The menu's own Download item, cell-scoped to dodge the page-
            // level label twin. Coordinate taps throughout: glass controls'
            // AX hit points can miss the real target on device, making
            // element.tap() a silent no-op (recorded during bring-up — the
            // page Download button ate five taps without starting).
            let menuDownload = app.cells.buttons["Download"].firstMatch
            if menuDownload.exists, menuDownload.isHittable {
                menuDownload.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                Thread.sleep(forTimeInterval: 8)
                continue
            }
            dismissMenu(in: app)

            // Exact identifier+label pin: only the not-yet-downloaded state
            // of the page control matches, so re-taps while a download runs
            // (or after it lands) are structurally impossible.
            let pageDownload = app.buttons.matching(
                NSPredicate(
                    format: "identifier == %@ AND label == %@",
                    "arrow.down.circle",
                    "Download"
                )
            ).firstMatch
            if pageDownload.exists, pageDownload.isHittable {
                pageDownload.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
            Thread.sleep(forTimeInterval: 8)
        }
        XCTFail("episode should offer Generate Transcript after downloading")
    }

    /// Transcript completion read from the Episode Actions menu: exactly
    /// "Delete Transcript" (no "Partial") exists only for a completed
    /// transcript. Menu polling avoids any scroll dependency.
    @MainActor
    private func waitForTranscriptCompleted(in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var lastScreenshotAt = Date.distantPast
        while Date() < deadline {
            openEpisodeActionsMenu(in: app)
            let completed = app.buttons["Delete Transcript"].waitForExistence(timeout: 3)
            dismissMenu(in: app)
            if completed {
                return true
            }
            if Date().timeIntervalSince(lastScreenshotAt) > 120 {
                attachTimestampedSmokeScreenshot(named: "transcription-progress")
                lastScreenshotAt = Date()
            }
            Thread.sleep(forTimeInterval: 15)
        }
        return false
    }

    // MARK: - Generated cards

    /// Sweeps the detail scroll view (down-up passes) until the probe says
    /// stop, leaving the view roughly where the probe first succeeded.
    @MainActor
    private func sweepDetail(in app: XCUIApplication, until probe: () -> Bool) {
        for pass in 0..<2 {
            if probe() {
                return
            }
            if pass > 0 {
                for _ in 0..<4 {
                    app.swipeDown()
                }
            }
            for _ in 0..<5 {
                if probe() {
                    return
                }
                app.swipeUp()
            }
        }
    }

    /// Both generated cards visible: the exact "Chapters" and "Summary" card
    /// headers (the controls card's "Chapters & Summary" label is a distinct
    /// exact-match miss).
    @MainActor
    private func waitForGeneratedCards(in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var lastScreenshotAt = Date.distantPast
        while Date() < deadline {
            var found = false
            sweepDetail(in: app) {
                staticText(exactly: "Chapters", in: app).exists
                    && staticText(exactly: "Summary", in: app).exists
            }
            found = staticText(exactly: "Chapters", in: app).exists
                && staticText(exactly: "Summary", in: app).exists
            if found {
                return true
            }
            if Date().timeIntervalSince(lastScreenshotAt) > 60 {
                attachTimestampedSmokeScreenshot(named: "awaiting-generated-cards")
                lastScreenshotAt = Date()
            }
            Thread.sleep(forTimeInterval: 10)
        }
        return false
    }

    /// The last chapter row (latest start time) plus its parsed start, from
    /// the row's "Chapter, <title>, starts at <time>" accessibility label.
    @MainActor
    private func lastChapter(in app: XCUIApplication) throws -> (XCUIElement, TimeInterval) {
        let chapters = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Chapter, ")
        )
        assertExists(chapters.firstMatch, named: "chapter rows", timeout: 10)
        let all = chapters.allElementsBoundByIndex.filter(\.exists)
        guard let last = all.last else {
            XCTFail("chapters card should carry at least one chapter row")
            return (chapters.firstMatch, 0)
        }
        for _ in 0..<4 where !last.isHittable {
            app.swipeUp()
        }
        let label = last.label
        guard let range = label.range(of: ", starts at ", options: .backwards) else {
            XCTFail("chapter label should carry a start time: \(label)")
            return (last, 0)
        }
        let time = label[range.upperBound...]
        let parts = time.split(separator: ":").compactMap { Double($0.filter(\.isNumber)) }
        let start = parts.reduce(0) { $0 * 60 + $1 }
        return (last, start)
    }

    // MARK: - Playback verification

    /// Opens Now Playing via the mini player and parses the progress
    /// slider's "<elapsed> elapsed, -<remaining> remaining" value.
    @MainActor
    private func readNowPlayingElapsed(in app: XCUIApplication) throws -> TimeInterval {
        let overlay = app.descendants(matching: .any)["Now Playing"]
        if !overlay.waitForExistence(timeout: 8) {
            let miniPlayer = app.buttons["Open Now Playing"]
            assertExists(miniPlayer, named: "mini player after chapter tap", timeout: 20)
            miniPlayer.tap()
            assertExists(overlay, named: "Now Playing overlay", timeout: 10)
        }

        let slider = app.sliders["Playback Progress"]
        assertExists(slider, named: "playback progress slider", timeout: 10)
        // Give the seek a beat to land before reading.
        Thread.sleep(forTimeInterval: 3)
        guard let value = slider.value as? String,
              let elapsedText = value.components(separatedBy: " elapsed").first
        else {
            XCTFail("progress slider should expose an elapsed value")
            return 0
        }
        let parts = elapsedText.split(separator: ":").compactMap { Double($0.filter(\.isNumber)) }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    @MainActor
    private func pausePlaybackIfPossible(in app: XCUIApplication) {
        let pause = app.buttons["Pause"].firstMatch
        if pause.waitForExistence(timeout: 5), pause.isHittable {
            pause.tap()
        }
    }

    // MARK: - Small shared helpers

    @MainActor
    private func staticText(containing label: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", label)).firstMatch
    }

    @MainActor
    private func staticText(exactly label: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }
}
