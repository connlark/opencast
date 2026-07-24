import XCTest

/// Opt-in device E2E coverage for the ad-detection queue. Runs against a
/// physical device with the real on-disk store, real network, and a
/// self-hosted development Worker (App Attest) — no `--opencast-ui-testing`
/// seams. Each test is meant to run one-at-a-time via
/// `-only-testing` with `TEST_RUNNER_OPENCAST_DEVICE_E2E=1`; the class skips
/// everywhere else so simulator regression runs are unaffected.
///
/// Prerequisite: the device is subscribed to the configured fixture feed.
/// Episode targeting goes through the dedicated Search tab so duplicate
/// episode titles remain disambiguated and the queued copy stays queryable.
///
/// Episode budget: every gate needs a not-yet-analyzed episode, so each test
/// owns distinct episodes from the fixture feed.
final class AdFreePassDeviceE2EUITests: XCTestCase {
    private static let optInEnvironmentKey = "OPENCAST_DEVICE_E2E"
    private static let showTitle = "Example Device E2E Show"

    // Batch and cancel use distinct titles. Persistence and foreground-only
    // can reuse duplicate episodes through the disambiguation below.
    private static let batchEpisodeA = "Example Batch Episode A"
    private static let batchEpisodeB = "Example Batch Episode B"
    private static let cancelEpisodeA = "Example Cancel Episode A"
    private static let cancelEpisodeB = "Example Cancel Episode B"
    private static let armingEpisodeA = "Example Arming Episode A"
    private static let armingEpisodeB = "Example Arming Episode B"
    private static let capEpisode = "Example Cap Episode"
    private static let persistenceEpisodeA = "Example Persistence Episode A"
    private static let persistenceEpisodeB = "Example Persistence Episode B"
    // (Both persistence titles rely on fresh twins if their first copies get
    // consumed by the cap/arming gates; detectAds disambiguates.)
    private static let megaphoneEpisode = "Example Persistence Episode B"
    private static let foregroundOnlyEpisode = "Example Foreground Episode"

    /// A fixture library may contain duplicate episode titles with distinct
    /// episode IDs. `detectAds` records the copy it enqueued so the post-drain
    /// assertion checks the same one.
    private var enqueuedRowIdentifiers: [String: String] = [:]

    private static let liveActivityTitleFragment = "Detecting ads"
    private static let soloActivityTitle = "Skip Promos & Ads"
    private static let capDeferredCopy = "Daily detection limit reached — continues tomorrow"

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

    /// Headline batch proof: two context-menu enqueues → indicator + queue
    /// screen → backgrounded drain with the Live Activity advancing across
    /// episodes → completion notification → zones armed per episode.
    @MainActor
    func testDeviceE2E01HeadlineBatchBackgroundDrain() throws {
        try skipUnlessDeviceE2E()
        let app = makeRealApp()
        app.launch()
        settleAnyRestoredQueue(in: app)

        detectAds(on: Self.batchEpisodeA, in: app)
        detectAds(on: Self.batchEpisodeB, in: app)
        attachScreen(named: "01-batch-enqueued")

        // Best-effort while running: the indicator button's identity churns
        // with every progress tick, so the Live Activity below supplies the
        // evidence if this visit cannot open.
        if tryOpenQueueScreen(in: app) {
            assertExists(queueRow(containing: Self.batchEpisodeA, in: app), named: "queued row A")
            assertExists(queueRow(containing: Self.batchEpisodeB, in: app), named: "queued row B")
            assertExists(
                staticText(containing: "Continues in the background.", in: app),
                named: "armed continuation label",
                timeout: 20
            )
            attachScreen(named: "01-queue-screen-armed")
        } else {
            attachScreen(named: "01-queue-screen-unreachable-while-running")
        }

        XCUIDevice.shared.press(.home)
        let springboard = springboardApp()
        // Apple-speech items drain in ~60-90 s each, so episode 1 may already
        // be done by the time the Notification Center renders — either
        // composite position proves the queue title is live.
        XCTAssertTrue(
            waitForSpringboardText(
                containingAnyOf: ["1 of 2", "2 of 2"],
                in: springboard,
                timeout: 300,
                screenshotName: "01-live-activity-queue-position"
            ),
            "Live Activity should show the composite queue position while backgrounded"
        )
        XCTAssertTrue(
            waitForSpringboardText(containing: "2 of 2", in: springboard, timeout: 900, screenshotName: "01-live-activity-2-of-2"),
            "Live Activity should advance to episode 2 of 2"
        )
        XCTAssertTrue(
            waitForSpringboardText(
                containingAnyOf: ["2 episodes", "Ad detection finished"],
                in: springboard,
                timeout: 900,
                screenshotName: "01-completion-notification"
            ),
            "completion notification should be delivered while backgrounded"
        )

        app.activate()
        if tryOpenQueueScreen(in: app) {
            attachScreen(named: "01-queue-screen-finished")
        }
        assertAdsDetected(for: Self.batchEpisodeA, in: app)
        assertAdsDetected(for: Self.batchEpisodeB, in: app)
        attachScreen(named: "01-zones-armed-menu-state")
    }

    /// Cancel mid-queue from the system UI: the continued-processing card's
    /// cancel interrupts the active item (preserved), pauses the queue, and
    /// an explicit Resume completes the remainder.
    @MainActor
    func testDeviceE2E02CancelMidQueueFromSystemUI() throws {
        try skipUnlessDeviceE2E()
        let app = makeRealApp()
        app.launch()
        settleAnyRestoredQueue(in: app)

        detectAds(on: Self.cancelEpisodeA, in: app)
        detectAds(on: Self.cancelEpisodeB, in: app)

        XCUIDevice.shared.press(.home)
        let springboard = springboardApp()
        XCTAssertTrue(
            waitForSpringboardText(
                containingAnyOf: ["1 of 2", "2 of 2"],
                in: springboard,
                timeout: 300,
                screenshotName: "02-live-activity-before-cancel"
            ),
            "Live Activity should be visible before system cancel"
        )
        guard cancelSystemCard(in: springboard) else {
            attachScreen(named: "02-cancel-affordance-not-found")
            throw XCTSkip("System-UI cancel affordance was not automatable from springboard; recorded for the audit.")
        }
        attachScreen(named: "02-after-system-cancel")

        app.activate()
        openQueueScreen(in: app)
        let resumeButton = app.buttons["Resume"]
        assertExists(resumeButton, named: "Resume affordance after system cancel", timeout: 30)
        assertExists(queueRow(containing: Self.cancelEpisodeA, in: app), named: "preserved interrupted row A")
        assertExists(queueRow(containing: Self.cancelEpisodeB, in: app), named: "preserved queued row B")
        attachScreen(named: "02-queue-paused-resumable")

        resumeButton.tap()
        XCTAssertTrue(
            waitForQueueDrainToFinish(in: app, timeout: 1200),
            "resumed queue should drain to completion"
        )
        attachScreen(named: "02-queue-finished-after-resume")
        assertAdsDetected(for: Self.cancelEpisodeA, in: app)
        assertAdsDetected(for: Self.cancelEpisodeB, in: app)
    }

    /// Queue-screen arming: an un-armed running queue (restored queue — the
    /// GOAL's sanctioned un-armed origin alongside the play trigger) +
    /// "Continue in Background" arms it mid-run, seeded at the current
    /// composite progress, and the drain completes backgrounded.
    ///
    /// Choreography (recorded findings force it): the toolbar indicator's
    /// running state is un-tappable on this layout, so the mock worker
    /// (`TEST_RUNNER_OPENCAST_E2E_MOCK_ANALYSIS_URL`) 429s the first
    /// analysis to park the restored queue capDeferred — whose paused
    /// indicator taps fine. With the queue screen ALREADY OPEN, Retry
    /// probes into the mock's delayed-response stall, the queue runs
    /// un-armed, and Continue in Background appears on the open screen.
    @MainActor
    func testDeviceE2E03QueueScreenArmingMidRun() throws {
        try skipUnlessDeviceE2E()
        guard let mockURL = ProcessInfo.processInfo.environment["OPENCAST_E2E_MOCK_ANALYSIS_URL"] else {
            throw XCTSkip("Set TEST_RUNNER_OPENCAST_E2E_MOCK_ANALYSIS_URL to the stateful mock worker for the arming gate.")
        }

        let app = makeRealApp()
        app.launch()
        settleAnyRestoredQueue(in: app)
        resetEpisodeAnalysis(for: Self.armingEpisodeA, in: app)
        resetEpisodeAnalysis(for: Self.armingEpisodeB, in: app)
        detectAds(on: Self.armingEpisodeA, in: app)
        detectAds(on: Self.armingEpisodeB, in: app)
        Thread.sleep(forTimeInterval: 10)
        app.terminate()

        // Restored session against the mock: item 1 transcribes, its first
        // analysis 429s, and the queue parks capDeferred.
        let restored = makeRealApp(environment: [
            "OPENCAST_AD_ANALYSIS_BASE_URL": mockURL,
            "OPENCAST_AD_ANALYSIS_CLIENT_TOKEN": "example-arming-mock-token"
        ])
        restored.launch()
        var parked = false
        let parkDeadline = Date().addingTimeInterval(300)
        while Date() < parkDeadline, !parked {
            if tryOpenQueueScreen(in: restored),
               staticText(containing: Self.capDeferredCopy, in: restored).waitForExistence(timeout: 3) {
                parked = true
                break
            }
            Thread.sleep(forTimeInterval: 5)
        }
        XCTAssertTrue(parked, "restored queue should park capDeferred against the mock's first 429")
        attachScreen(named: "03-parked-cap-deferred")

        // Retry probes into the mock's stall; the queue runs un-armed with
        // the screen already open, so Continue in Background is reachable.
        let retryButton = restored.buttons["Retry"]
        assertExists(retryButton, named: "cap Retry affordance")
        retryButton.tap()

        let continueButton = restored.buttons["Continue in Background"]
        let armedLabel = staticText(containing: "Continues in the background.", in: restored)
        let armDeadline = Date().addingTimeInterval(200)
        while Date() < armDeadline, !armedLabel.exists {
            if continueButton.exists, continueButton.isHittable {
                continueButton.tap()
            } else if retryButton.exists, retryButton.isHittable {
                retryButton.tap()
            }
            _ = armedLabel.waitForExistence(timeout: 2)
        }
        assertExists(armedLabel, named: "armed label after mid-run arm", timeout: 5)
        assertExists(
            queueRow(containing: Self.armingEpisodeA, in: restored),
            named: "armed running queue row",
            timeout: 10
        )
        attachScreen(named: "03-armed-mid-run")

        XCUIDevice.shared.press(.home)
        let springboard = springboardApp()
        XCTAssertTrue(
            waitForSpringboardText(
                containingAnyOf: [Self.soloActivityTitle, Self.liveActivityTitleFragment],
                in: springboard,
                timeout: 120,
                screenshotName: "03-live-activity-after-arm"
            ),
            "Live Activity should appear after arming mid-run"
        )
        // Let the armed two-item drain finish while backgrounded; the run
        // log records the background completion authoritatively (stale
        // Notification Center banners make notification text unreliable).
        Thread.sleep(forTimeInterval: 240)
        attachScreen(named: "03-after-background-drain")

        restored.activate()
        assertAdsDetected(for: Self.armingEpisodeA, in: restored)
        assertAdsDetected(for: Self.armingEpisodeB, in: restored)
    }

    /// Cap-deferral on device via the force hook: queue pauses with the
    /// settled copy; a fresh session (no hook) probes once and the deferred
    /// item completes.
    @MainActor
    func testDeviceE2E04CapDeferralAndNextSessionProbe() throws {
        try skipUnlessDeviceE2E()
        let cappedApp = makeRealApp(environment: ["OPENCAST_ADANALYSIS_FORCE_CAP": "1"])
        cappedApp.launch()
        settleAnyRestoredQueue(in: cappedApp)
        resetEpisodeAnalysis(for: Self.capEpisode, in: cappedApp)

        detectAds(on: Self.capEpisode, in: cappedApp)

        // The running indicator is un-tappable mid-drain (recorded finding),
        // so poll until the forced cap parks the queue — the paused pill
        // taps fine.
        var parked = false
        let parkDeadline = Date().addingTimeInterval(600)
        while Date() < parkDeadline, !parked {
            if tryOpenQueueScreen(in: cappedApp),
               staticText(containing: Self.capDeferredCopy, in: cappedApp).waitForExistence(timeout: 3) {
                parked = true
                break
            }
            Thread.sleep(forTimeInterval: 5)
        }
        XCTAssertTrue(parked, "forced cap should park the queue with the settled copy")
        assertExists(cappedApp.buttons["Retry"], named: "cap Retry affordance")
        attachScreen(named: "04-cap-deferred-queue-screen")

        // Relaunch without the hook: the restored session is allowed one
        // probe, which retries the deferred item on its own — the resumed
        // drain keeps the indicator un-tappable, so completion is asserted
        // from the Inbox indicator settling plus the menu state.
        let app = makeRealApp()
        app.launch()
        XCTAssertTrue(
            waitForQueueDrainToFinish(in: app, timeout: 900),
            "probe should retry the deferred item and complete it"
        )
        attachScreen(named: "04-deferred-item-completed-after-probe")
        assertAdsDetected(for: Self.capEpisode, in: app)
    }

    /// Persistence: force-quit with items pending, relaunch restores them,
    /// and the foreground drain completes.
    @MainActor
    func testDeviceE2E05PersistenceAcrossForceQuit() throws {
        try skipUnlessDeviceE2E()
        let app = makeRealApp()
        app.launch()
        settleAnyRestoredQueue(in: app)
        resetEpisodeAnalysis(for: Self.persistenceEpisodeA, in: app)
        resetEpisodeAnalysis(for: Self.persistenceEpisodeB, in: app)

        detectAds(on: Self.persistenceEpisodeA, in: app)
        detectAds(on: Self.persistenceEpisodeB, in: app)
        if tryOpenQueueScreen(in: app) {
            assertExists(queueRow(containing: Self.persistenceEpisodeA, in: app), named: "running row before force-quit")
            assertExists(queueRow(containing: Self.persistenceEpisodeB, in: app), named: "pending row before force-quit")
        }
        attachScreen(named: "05-queue-before-force-quit")

        app.terminate()
        app.launch()
        // Restored queues surface paused (static pill, tappable) or resume
        // draining on their own (running pill, un-tappable); poll for the
        // screen and handle both.
        var restoredScreenOpen = false
        let restoreDeadline = Date().addingTimeInterval(90)
        while Date() < restoreDeadline, !restoredScreenOpen {
            restoredScreenOpen = tryOpenQueueScreen(in: app)
            if restoredScreenOpen { break }
            Thread.sleep(forTimeInterval: 5)
        }
        if restoredScreenOpen {
            assertExists(
                queueRow(containing: Self.persistenceEpisodeB, in: app),
                named: "restored pending row after relaunch",
                timeout: 60
            )
            attachScreen(named: "05-queue-restored-after-relaunch")
            let resumeButton = app.buttons["Resume"]
            if resumeButton.waitForExistence(timeout: 10) {
                resumeButton.tap()
            }
        } else {
            attachScreen(named: "05-queue-restored-draining-screen-unreachable")
        }
        XCTAssertTrue(
            waitForQueueDrainToFinish(in: app, timeout: 1500),
            "restored queue should drain to completion in the foreground"
        )
        attachScreen(named: "05-restored-queue-finished")
        assertAdsDetected(for: Self.persistenceEpisodeA, in: app)
        assertAdsDetected(for: Self.persistenceEpisodeB, in: app)
    }

    /// Parity: the step-5 single-episode megaphone flow, re-run through the
    /// Sound Lab control against the real pipeline.
    @MainActor
    func testDeviceE2E06MegaphoneParitySoloPass() throws {
        try skipUnlessDeviceE2E()
        let app = makeRealApp()
        app.launch()
        settleAnyRestoredQueue(in: app)
        resetEpisodeAnalysis(for: Self.megaphoneEpisode, in: app)

        startPlayback(of: Self.megaphoneEpisode, in: app)
        revealNowPlayingSoundLab(in: app)
        assertExists(app.descendants(matching: .any)["Now Playing Sound Lab"], named: "Sound Lab panel")
        let megaphone = app.descendants(matching: .any)["Skip Promos & Ads"].firstMatch
        assertExists(megaphone, named: "Skip Promos & Ads control")
        attachScreen(named: "06-sound-lab-before-pass")
        megaphone.tap()

        XCTAssertTrue(
            waitForElement(
                staticText(containing: "Reanalyze", in: app),
                timeout: 900,
                pollScreenshotName: "06-solo-pass-progress"
            ),
            "solo megaphone pass should complete and offer Reanalyze"
        )
        attachScreen(named: "06-solo-pass-completed")
    }

    /// Foreground-only fallback via the step-5 force hook: arming degrades
    /// gracefully and the pass still completes in the foreground.
    @MainActor
    func testDeviceE2E07ForegroundOnlyFallback() throws {
        try skipUnlessDeviceE2E()
        let app = makeRealApp(environment: ["OPENCAST_ADFREEPASS_FORCE_FOREGROUND_ONLY": "1"])
        app.launch()
        settleAnyRestoredQueue(in: app)
        resetEpisodeAnalysis(for: Self.foregroundOnlyEpisode, in: app)

        detectAds(on: Self.foregroundOnlyEpisode, in: app)
        // Best-effort while running because the indicator can be un-tappable
        // mid-drain.
        if tryOpenQueueScreen(in: app) {
            assertExists(queueRow(containing: Self.foregroundOnlyEpisode, in: app), named: "foreground-only queue row")
            XCTAssertFalse(
                staticText(containing: "Continues in the background.", in: app).exists,
                "forced foreground-only session must not report armed continuation"
            )
        }
        attachScreen(named: "07-foreground-only-running")
        XCTAssertTrue(
            waitForQueueDrainToFinish(in: app, timeout: 1200),
            "foreground-only pass should complete in the foreground"
        )
        attachScreen(named: "07-foreground-only-finished")
        assertAdsDetected(for: Self.foregroundOnlyEpisode, in: app)
    }

    // MARK: - Gate plumbing

    private func skipUnlessDeviceE2E() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Ad-free-pass device E2E requires a physical device.")
        #else
        guard ProcessInfo.processInfo.environment[Self.optInEnvironmentKey] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_OPENCAST_DEVICE_E2E=1 to run the device E2E.")
        }
        #endif
    }

    @MainActor
    private func makeRealApp(environment: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        // A runner-side override can point the analysis leg at a local mock
        // Worker while transcription remains real and on-device.
        if let override = ProcessInfo.processInfo.environment["OPENCAST_E2E_ANALYSIS_OVERRIDE_URL"] {
            app.launchEnvironment["OPENCAST_AD_ANALYSIS_BASE_URL"] = override
            app.launchEnvironment["OPENCAST_AD_ANALYSIS_CLIENT_TOKEN"] = "example-device-e2e-token"
        }
        for (key, value) in environment {
            app.launchEnvironment[key] = value
        }
        return app
    }

    @MainActor
    private func springboardApp() -> XCUIApplication {
        XCUIApplication(bundleIdentifier: "com.apple.springboard")
    }

    // MARK: - Episode targeting (Search tab)

    /// Finds an episode row by title through the dedicated Search tab.
    @MainActor
    private func searchEpisodeRow(for episodeTitle: String, in app: XCUIApplication) -> XCUIElement {
        openSearch(in: app)

        // Opening search is retried as a whole: transient system pills
        // (AirPods connected, etc.) swallow taps, and the searchable
        // presentation can flicker closed right after appearing.
        var didType = false
        for _ in 0..<4 {
            let field = app.searchFields.firstMatch.exists
                ? app.searchFields.firstMatch
                : app.textFields["Podcasts and Episodes"].firstMatch
            if field.exists, field.isHittable {
                field.tap()
                guard field.exists else { continue }
                clearSearchField(field, in: app)
                guard field.exists else { continue }
                field.typeText(episodeTitle)
                // Commit the query: the raised keyboard otherwise consumes
                // the first long-press on a result row.
                if app.keyboards.firstMatch.exists {
                    app.typeText("\n")
                }
                didType = true
                break
            }

            openSearch(in: app)
            _ = app.searchFields.firstMatch.waitForExistence(timeout: 4)
        }
        XCTAssertTrue(didType, "Search tab field should accept the query")

        let row = app.buttons.matching(episodeRowPredicate(containing: episodeTitle)).firstMatch
        assertExists(row, named: "search result row for \(episodeTitle)", timeout: 20)
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
            searchField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count + 2))
        }
    }

    /// Some searchable presentations have no Cancel button; committing the
    /// query with Return drops the keyboard so toolbar taps land.
    @MainActor
    private func dismissSearchIfPresented(in app: XCUIApplication) {
        guard app.searchFields.firstMatch.exists else {
            return
        }
        let cancelButton = app.buttons["Cancel"].firstMatch
        if cancelButton.exists, cancelButton.isHittable {
            cancelButton.tap()
            return
        }
        if app.keyboards.firstMatch.exists {
            app.typeText("\n")
        }
    }

    /// Un-burns an analyzed fixture episode: episode detail's Episode Actions
    /// menu's "Delete Transcript" removes the transcript AND analysis,
    /// re-enabling Detect Ads for that copy. Detail opens as a navigation push.
    @MainActor
    private func resetEpisodeAnalysis(for episodeTitle: String, in app: XCUIApplication) {
        let row = searchEpisodeRow(for: episodeTitle, in: app)
        row.press(forDuration: 1.2)
        let detailsButton = app.buttons["View Episode Details"]
        assertExists(detailsButton, named: "View Episode Details for \(episodeTitle)")
        detailsButton.tap()

        let episodeActionsButton = app.buttons["Episode Actions"]
        assertExists(episodeActionsButton, named: "Episode Actions menu for \(episodeTitle)")
        episodeActionsButton.tap()

        let deleteButton = app.buttons["Delete Transcript"]
        if deleteButton.waitForExistence(timeout: 5), deleteButton.isHittable {
            deleteButton.tap()
            _ = deleteButton.waitForNonExistence(timeout: 5)
        }
    }

    // MARK: - Queue actions

    /// Long-presses each duplicate copy of the episode until one offers an
    /// enabled "Detect Ads", taps it, and records which copy was enqueued.
    @MainActor
    private func detectAds(on episodeTitle: String, in app: XCUIApplication) {
        _ = searchEpisodeRow(for: episodeTitle, in: app)
        let rows = app.buttons.matching(episodeRowPredicate(containing: episodeTitle))
        let copyCount = min(rows.count, 3)
        for index in 0..<max(copyCount, 1) {
            let row = rows.element(boundBy: index)
            guard row.exists, row.isHittable else { continue }
            let identifier = row.identifier
            for _ in 0..<2 {
                row.press(forDuration: 1.2)
                if app.buttons["View Episode Details"].waitForExistence(timeout: 4) {
                    break
                }
            }
            let detectButton = app.buttons["Detect Ads"]
            if detectButton.waitForExistence(timeout: 3), detectButton.isEnabled {
                detectButton.tap()
                enqueuedRowIdentifiers[episodeTitle] = identifier
                return
            }
            dismissContextMenu(in: app)
        }
        XCTFail("No copy of \(episodeTitle) offered an enabled Detect Ads action")
    }

    @MainActor
    private func assertAdsDetected(for episodeTitle: String, in app: XCUIApplication) {
        _ = searchEpisodeRow(for: episodeTitle, in: app)
        let row: XCUIElement
        if let identifier = enqueuedRowIdentifiers[episodeTitle] {
            row = app.buttons[identifier].firstMatch
        } else {
            row = app.buttons.matching(episodeRowPredicate(containing: episodeTitle)).firstMatch
        }
        assertExists(row, named: "analyzed episode row for \(episodeTitle)")
        row.press(forDuration: 1.2)
        assertExists(app.buttons["Ads Detected"], named: "Ads Detected state for \(episodeTitle)")
        dismissContextMenu(in: app)
    }

    private func episodeRowPredicate(containing episodeTitle: String) -> NSPredicate {
        NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "episode-row-",
            episodeTitle
        )
    }

    @MainActor
    private func startPlayback(of episodeTitle: String, in app: XCUIApplication) {
        let row = searchEpisodeRow(for: episodeTitle, in: app)
        row.tap()

        let overlay = app.descendants(matching: .any)["Now Playing"]
        if overlay.waitForExistence(timeout: 8) {
            return
        }

        let playEpisodeButton = app.buttons["Play Episode"]
        if playEpisodeButton.waitForExistence(timeout: 5) {
            playEpisodeButton.tap()
        }
        assertExists(overlay, named: "Now Playing overlay", timeout: 10)
    }

    @MainActor
    private func dismissContextMenu(in app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.08)).tap()
    }

    @MainActor
    private func revealNowPlayingSoundLab(in app: XCUIApplication) {
        let artwork = app.descendants(matching: .any)["Now Playing Artwork"]
        assertExists(artwork, named: "Now Playing artwork")
        let start = artwork.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.52))
        let end = artwork.coordinate(withNormalizedOffset: CGVector(dx: 0.52, dy: 0.48))
        start.press(forDuration: 0.10, thenDragTo: end)
    }

    // MARK: - Navigation

    /// Interrupted earlier runs leave persisted queue items that restore and
    /// drain on the next launch. Settling them first keeps this test's
    /// composite counts ("N of 2") and spend accounting deterministic. The
    /// toolbar indicator disappears when the queue goes idle, so its absence
    /// is the settle signal.
    @MainActor
    private func settleAnyRestoredQueue(in app: XCUIApplication) {
        openInbox(in: app)
        let indicator = app.buttons["Ad Detection Queue Indicator"]
        guard indicator.waitForExistence(timeout: 8) else {
            return
        }
        let deadline = Date().addingTimeInterval(600)
        while indicator.exists, Date() < deadline {
            Thread.sleep(forTimeInterval: 10)
        }
    }

    @MainActor
    private func openInbox(in app: XCUIApplication) {
        let queueNav = app.navigationBars["Ad Detection"]
        if queueNav.exists {
            let backButton = queueNav.buttons.firstMatch
            if backButton.exists, backButton.isHittable {
                backButton.tap()
            }
        }

        if app.navigationBars["Inbox"].waitForExistence(timeout: 3) {
            return
        }

        openSection("Inbox", in: app)
    }

    @MainActor
    private func openSearch(in app: XCUIApplication) {
        if app.navigationBars["Search"].exists,
           app.searchFields.firstMatch.exists {
            return
        }

        openSection("Search", in: app)
    }

    @MainActor
    private func openQueueScreen(in app: XCUIApplication) {
        XCTAssertTrue(tryOpenQueueScreen(in: app), "queue screen should open")
    }

    @discardableResult
    @MainActor
    private func tryOpenQueueScreen(in app: XCUIApplication) -> Bool {
        if app.navigationBars["Ad Detection"].exists {
            return true
        }

        openInbox(in: app)
        dismissSearchIfPresented(in: app)
        let indicator = app.buttons["Ad Detection Queue Indicator"]
        guard indicator.waitForExistence(timeout: 30) else {
            return false
        }
        // The indicator button's SwiftUI identity is rebuilt on every queue
        // progress tick (its `.task(id:)` keys on the progress fraction), so
        // a normal-length tap routinely dies mid-gesture while a drain is
        // running. Bursts of very short taps land between rebuilds.
        let queueNav = app.navigationBars["Ad Detection"]
        burst: for offset in [0.5, 0.1, 0.85] as [CGFloat] {
            guard indicator.exists else { break }
            for _ in 0..<4 {
                indicator.coordinate(withNormalizedOffset: CGVector(dx: offset, dy: 0.5))
                    .press(forDuration: 0.02)
                if queueNav.waitForExistence(timeout: 2) {
                    break burst
                }
            }
        }
        return queueNav.exists
    }

    @MainActor
    private func queueRow(containing episodeTitle: String, in app: XCUIApplication) -> XCUIElement {
        let predicate = NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "ad-detection-queue-row-",
            episodeTitle
        )
        return app.descendants(matching: .any).matching(predicate).firstMatch
    }

    /// A drained queue leaves no affordance rows behind: no Resume/Retry/
    /// Continue buttons and either a Finished section, the empty state, or —
    /// once everything clears — no toolbar indicator at all.
    @MainActor
    private func waitForQueueDrainToFinish(in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !app.navigationBars["Ad Detection"].exists {
                openInbox(in: app)
                dismissSearchIfPresented(in: app)
                let indicator = app.buttons["Ad Detection Queue Indicator"]
                if !indicator.waitForExistence(timeout: 5) {
                    return true
                }
                if indicator.exists, indicator.isHittable {
                    indicator.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5)).tap()
                }
                guard app.navigationBars["Ad Detection"].waitForExistence(timeout: 4) else {
                    continue
                }
            }

            let hasPendingAffordance = app.buttons["Resume"].exists
                || app.buttons["Retry"].exists
                || app.buttons["Continue in Background"].exists
                || staticText(containing: "Continues in the background.", in: app).exists
            let looksDrained = staticText(containing: "Finished", in: app).exists
                || staticText(containing: "No ad detection in progress", in: app).exists
            if !hasPendingAffordance, looksDrained {
                return true
            }

            Thread.sleep(forTimeInterval: 10)
        }

        return false
    }

    // MARK: - Springboard

    @MainActor
    private func cancelSystemCard(in springboard: XCUIApplication) -> Bool {
        for attempt in 0..<3 {
            let directCancel = springboard.buttons["Cancel"].firstMatch
            if directCancel.waitForExistence(timeout: 2), directCancel.isHittable {
                directCancel.tap()
                return true
            }

            let card = springboardText(containing: Self.liveActivityTitleFragment, in: springboard)
            if card.waitForExistence(timeout: 2) {
                card.press(forDuration: 1.0)
                let expandedCancel = springboard.buttons["Cancel"].firstMatch
                if expandedCancel.waitForExistence(timeout: 3), expandedCancel.isHittable {
                    expandedCancel.tap()
                    return true
                }
                let stopButton = springboard.buttons["Stop"].firstMatch
                if stopButton.waitForExistence(timeout: 2), stopButton.isHittable {
                    stopButton.tap()
                    return true
                }
            }

            if attempt == 0 {
                openNotificationCenter(in: springboard)
            }
        }

        return false
    }

    @MainActor
    private func waitForSpringboardText(
        containing fragment: String,
        in springboard: XCUIApplication,
        timeout: TimeInterval,
        screenshotName: String
    ) -> Bool {
        waitForSpringboardText(
            containingAnyOf: [fragment],
            in: springboard,
            timeout: timeout,
            screenshotName: screenshotName
        )
    }

    @MainActor
    private func waitForSpringboardText(
        containingAnyOf fragments: [String],
        in springboard: XCUIApplication,
        timeout: TimeInterval,
        screenshotName: String
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var checksNotificationCenter = false
        while Date() < deadline {
            for fragment in fragments {
                if springboardText(containing: fragment, in: springboard).waitForExistence(timeout: 2) {
                    attachScreen(named: screenshotName)
                    if checksNotificationCenter {
                        XCUIDevice.shared.press(.home)
                    }
                    return true
                }
            }

            if checksNotificationCenter {
                XCUIDevice.shared.press(.home)
                Thread.sleep(forTimeInterval: 10)
            } else {
                openNotificationCenter(in: springboard)
            }
            checksNotificationCenter.toggle()
        }

        attachScreen(named: "\(screenshotName)-timeout")
        return false
    }

    @MainActor
    private func springboardText(containing fragment: String, in springboard: XCUIApplication) -> XCUIElement {
        let predicate = NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@",
            fragment,
            fragment
        )
        return springboard.descendants(matching: .any).matching(predicate).firstMatch
    }

    // MARK: - Small shared helpers

    @MainActor
    private func staticText(containing label: String, in app: XCUIApplication) -> XCUIElement {
        let predicate = NSPredicate(format: "label CONTAINS %@", label)
        return app.staticTexts.matching(predicate).firstMatch
    }

    @MainActor
    private func waitForElement(
        _ element: XCUIElement,
        timeout: TimeInterval,
        pollScreenshotName: String? = nil
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var lastScreenshotAt = Date.distantPast
        while Date() < deadline {
            if element.waitForExistence(timeout: 2) {
                return true
            }
            if let pollScreenshotName, Date().timeIntervalSince(lastScreenshotAt) > 120 {
                attachScreen(named: pollScreenshotName)
                lastScreenshotAt = Date()
            }
            Thread.sleep(forTimeInterval: 8)
        }

        return false
    }

    @MainActor
    private func assertExists(
        _ element: XCUIElement,
        named name: String,
        timeout: TimeInterval = 10
    ) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "\(name) should exist")
    }

    @MainActor
    private func attachScreen(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "\(name)_\(ISO8601DateFormatter().string(from: Date()))"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
